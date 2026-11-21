import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_scanner_offline_private/src/contrast.dart';
import 'package:qr_scanner_offline_private/src/decoder.dart';
import 'package:qr_scanner_offline_private/src/frame_worker.dart';

CameraImage _image(
  List<int> bytes, {
  int width = 2,
  int height = 2,
  required int bytesPerRow,
  int? bytesPerPixel,
  ImageFormatGroup format = ImageFormatGroup.yuv420,
}) => CameraImage.fromPlatformInterface(
  CameraImageData(
    format: CameraImageFormat(format, raw: 0),
    height: height,
    width: width,
    planes: [
      CameraImagePlane(
        bytes: Uint8List.fromList(bytes),
        bytesPerRow: bytesPerRow,
        bytesPerPixel: bytesPerPixel,
      ),
    ],
  ),
);

class _TrackingAllocator implements Allocator {
  _TrackingAllocator({this.failAt});

  final int? failAt;
  int allocations = 0;
  final live = <Pointer<NativeType>, int>{};

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    if (++allocations == failAt) throw ArgumentError('Allocation failed.');
    final pointer = malloc.allocate<T>(byteCount, alignment: alignment);
    live[pointer] = byteCount;
    return pointer;
  }

  @override
  void free(Pointer<NativeType> pointer) {
    live.remove(pointer);
    malloc.free(pointer);
  }
}

void main() {
  group('luma conversion', () {
    test('skips YUV row padding', () {
      final image = _image([1, 2, 255, 3, 4], bytesPerRow: 3);
      expect(lumaFrame(image).pixels, orderedEquals([1, 2, 3, 4]));
      expect(image.planes.first.bytes, orderedEquals([1, 2, 255, 3, 4]));
    });

    test('honors a YUV pixel stride greater than one', () {
      final image = _image(
        [1, 255, 2, 255, 3, 255, 4],
        bytesPerRow: 4,
        bytesPerPixel: 2,
      );
      expect(lumaFrame(image).pixels, orderedEquals([1, 2, 3, 4]));
    });

    test('computes BGRA luminance and skips alpha and padding', () {
      final image = _image(
        [0, 0, 255, 8, 0, 255, 0, 7, 42, 255, 0, 0, 6, 255, 255, 255, 5],
        bytesPerRow: 9,
        format: ImageFormatGroup.bgra8888,
      );
      expect(lumaFrame(image).pixels, orderedEquals([76, 149, 28, 255]));
    });

    test('rejects unsupported formats and inconsistent planes', () {
      expect(
        () => lumaFrame(
          _image([], bytesPerRow: 2, format: ImageFormatGroup.jpeg),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => lumaFrame(_image([1, 2, 3], bytesPerRow: 2)),
        throwsArgumentError,
      );
      expect(
        () => lumaFrame(_image([1, 2, 3, 4], bytesPerRow: 1)),
        throwsArgumentError,
      );
      expect(
        () => lumaFrame(_image([1, 2, 3, 4], bytesPerRow: 2, bytesPerPixel: 0)),
        throwsArgumentError,
      );
    });

    test('includes only pixels fully contained in the raw frame region', () {
      final image = _image(
        [1, 2, 3, 4, 255, 5, 6, 7, 8, 255, 9, 10, 11, 12],
        width: 4,
        height: 3,
        bytesPerRow: 5,
      );
      final layout = LumaLayout.fromImage(image);
      final bytes = image.planes.first.bytes;
      final frame = layout.extract(
        bytes,
        region: const Rect.fromLTRB(0.1, 0, 0.8, 0.8),
      );
      expect(frame?.width, 2);
      expect(frame?.height, 2);
      expect(frame?.pixels, orderedEquals([2, 3, 6, 7]));
      expect(
        layout.extract(bytes, region: const Rect.fromLTRB(0.1, 0, 0.2, 1)),
        isNull,
      );
      expect(
        () => layout.extract(bytes, region: const Rect.fromLTRB(0, 0, 1.1, 1)),
        throwsArgumentError,
      );
    });
  });

  group('frame decoding', () {
    test('validates frame size before using the platform decoder', () {
      for (final (width, height) in [(0, 1), (2, 2), (maxFramePixels + 1, 1)]) {
        expect(
          () => decodeFrame(Frame(Uint8List(1), width, height)),
          throwsArgumentError,
        );
      }
    });

    test('frees the first allocation if the second fails', () {
      final allocator = _TrackingAllocator(failAt: 2);
      final decoder = FrameDecoder(
        allocator: allocator,
        decodePixels: (input, width, height, output, capacity) => 0,
      );
      try {
        expect(
          () => decoder.decode(Frame(Uint8List(1), 1, 1)),
          throwsArgumentError,
        );
        expect(allocator.live, isEmpty);
      } finally {
        decoder.dispose();
      }
    });

    test('reuses and clears native buffers after decoding UTF-8', () {
      final allocator = _TrackingAllocator();
      const text = 'QR café';
      final payload = utf8.encode(text);
      final decoder = FrameDecoder(
        allocator: allocator,
        decodePixels: (input, width, height, output, capacity) {
          expect(input.asTypedList(width * height), everyElement(42));
          output.asTypedList(capacity).setRange(0, payload.length, payload);
          return payload.length;
        },
      );
      final pixels = Uint8List.fromList([42, 42]);
      try {
        expect(decoder.decode(Frame(pixels, 2, 1)), text);
        expect(decoder.decode(Frame(pixels, 1, 2)), text);
        expect(allocator.allocations, 2);
        for (final entry in allocator.live.entries) {
          expect(
            entry.key.cast<Uint8>().asTypedList(entry.value),
            everyElement(0),
          );
        }
        expect(pixels, everyElement(42));
      } finally {
        decoder.dispose();
      }
    });

    test('runs the adaptive retry only when requested', () {
      var calls = 0;
      final decoder = FrameDecoder(
        decodePixels: (input, width, height, output, capacity) {
          calls++;
          return 0;
        },
      );
      final frame = Frame(Uint8List(4), 2, 2);
      try {
        expect(decoder.decode(frame), isNull);
        expect(calls, 2);
        expect(decoder.decode(frame, useAdaptiveThreshold: false), isNull);
        expect(calls, 3);
      } finally {
        decoder.dispose();
      }
    });

    test(
      'reports native capacity errors and discards malformed text details',
      () {
        var nativeStatus = -2;
        final decoder = FrameDecoder(
          decodePixels: (input, width, height, output, capacity) {
            output.asTypedList(1)[0] = 0xff;
            return nativeStatus;
          },
        );
        final frame = Frame(Uint8List(1), 1, 1);
        try {
          expect(
            () => decoder.decode(frame),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('capacity'),
              ),
            ),
          );
          nativeStatus = 1;
          expect(
            () => decoder.decode(frame),
            throwsA(
              isA<FormatException>().having((e) => e.source, 'source', isNull),
            ),
          );
        } finally {
          decoder.dispose();
        }
      },
    );
  });

  test(
    'worker can reuse its isolate and exit with an in-flight frame',
    () async {
      final worker = await FrameWorker.start();
      try {
        final image = _image([1, 2, 3, 4], bytesPerRow: 2);
        // A subpixel crop is resolved on the worker without calling FFI.
        const region = Rect.fromLTRB(0, 0, 0.1, 1);
        expect(await worker.decode(image, frameRegion: region), isNull);
        final result = worker.decode(image, frameRegion: region);
        final exit = worker.close();
        expect(await result, isNull);
        await exit;
        await expectLater(worker.decode(image), throwsStateError);
      } finally {
        await worker.close();
      }
    },
  );
}
