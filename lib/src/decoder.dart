import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:ffi/ffi.dart';

import 'contrast.dart';
import 'qr_decoder.g.dart';

class Frame {
  const Frame(this.pixels, this.width, this.height);
  final Uint8List pixels;
  final int width;
  final int height;
}

/// Copies the luminance of a YUV420 or BGRA8888 camera frame.
Frame lumaFrame(CameraImage image) =>
    LumaLayout.fromImage(image).extract(image.planes.first.bytes)!;

void validateFrameRegion(Rect? region) {
  if (region != null &&
      (!region.isFinite ||
          region.isEmpty ||
          region.left < 0 ||
          region.top < 0 ||
          region.right > 1 ||
          region.bottom > 1)) {
    throw ArgumentError('The frame region must be a non-empty unit rectangle.');
  }
}

/// A validated description of the first camera plane, without its bytes.
class LumaLayout {
  LumaLayout.fromImage(CameraImage image)
    : width = image.width,
      height = image.height,
      bgra = image.format.group == ImageFormatGroup.bgra8888 {
    validateFrameDimensions(width, height);
    if (!bgra && image.format.group != ImageFormatGroup.yuv420) {
      throw UnsupportedError('Unsupported camera image format.');
    }
    if (image.planes.isEmpty) {
      throw ArgumentError('Missing camera image plane.');
    }
    final plane = image.planes.first;
    final bytesPerPixel = bgra ? 4 : 1;
    rowStride = plane.bytesPerRow;
    pixelStride = plane.bytesPerPixel ?? bytesPerPixel;
    if (rowStride < bytesPerPixel ||
        pixelStride < bytesPerPixel ||
        width - 1 > (rowStride - bytesPerPixel) ~/ pixelStride) {
      throw ArgumentError('Invalid camera image plane stride.');
    }
    final rowBytes = (width - 1) * pixelStride + bytesPerPixel;
    if (plane.bytes.length < rowBytes ||
        height - 1 > (plane.bytes.length - rowBytes) ~/ rowStride) {
      throw ArgumentError('Truncated camera image plane.');
    }
    byteLength = (height - 1) * rowStride + rowBytes;
  }

  final int width;
  final int height;
  final bool bgra;
  late final int rowStride;
  late final int pixelStride;
  late final int byteLength;

  Frame? extract(Uint8List bytes, {Rect? region}) {
    validateFrameRegion(region);
    // Use only pixels fully contained in the requested region.
    final left = region == null ? 0 : (region.left * width).ceil();
    final top = region == null ? 0 : (region.top * height).ceil();
    final right = region == null ? width : (region.right * width).floor();
    final bottom = region == null ? height : (region.bottom * height).floor();
    final croppedWidth = right - left;
    final croppedHeight = bottom - top;
    if (croppedWidth <= 0 || croppedHeight <= 0) return null;

    final output = Uint8List(croppedWidth * croppedHeight);
    for (var y = 0; y < croppedHeight; y++) {
      final sourceRow = (top + y) * rowStride + left * pixelStride;
      final targetRow = y * croppedWidth;
      if (!bgra && pixelStride == 1) {
        output.setRange(targetRow, targetRow + croppedWidth, bytes, sourceRow);
        continue;
      }
      for (var x = 0; x < croppedWidth; x++) {
        final i = sourceRow + x * pixelStride;
        if (bgra) {
          final b = bytes[i], g = bytes[i + 1], r = bytes[i + 2];
          output[targetRow + x] = (r * 77 + g * 150 + b * 29) >> 8;
        } else {
          output[targetRow + x] = bytes[i];
        }
      }
    }
    return Frame(output, croppedWidth, croppedHeight);
  }
}

String? decodeFrame(Frame frame) {
  final decoder = FrameDecoder();
  try {
    return decoder.decode(frame);
  } finally {
    decoder.dispose();
  }
}

typedef DecodePixels = int Function(
  Pointer<Uint8> pixels,
  int width,
  int height,
  Pointer<Uint8> output,
  int capacity,
);

/// Owns scratch buffers for a series of synchronous decodes on one isolate.
class FrameDecoder {
  FrameDecoder({this._allocator = malloc, this._decodePixels});

  static const _capacity = 16384;

  final Allocator _allocator;
  final DecodePixels? _decodePixels;
  Pointer<Uint8>? _input;
  int _inputCapacity = 0;
  Pointer<Uint8>? _output;
  Uint32List? _integral;

  String? decode(Frame frame, {bool useAdaptiveThreshold = true}) {
    final width = frame.width;
    final height = frame.height;
    validateFrameDimensions(width, height);
    if (frame.pixels.length != width * height) {
      throw ArgumentError('The luma buffer does not match the frame size.');
    }
    if (_decodePixels == null && !Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError('The decoder is unavailable on this platform.');
    }

    final decodePixels = _decodePixels ?? qr_decode;
    final size = frame.pixels.length;
    try {
      if (_inputCapacity < size) {
        final nextInput = _allocator.allocate<Uint8>(size);
        final previousInput = _input;
        _input = nextInput;
        _inputCapacity = size;
        if (previousInput != null) _allocator.free(previousInput);
      }
      _output ??= _allocator.allocate<Uint8>(_capacity);
    } catch (_) {
      dispose();
      rethrow;
    }
    final input = _input!;
    final output = _output!;
    final inputBytes = input.asTypedList(size);
    final outputBytes = output.asTypedList(_capacity);
    try {
      inputBytes.setRange(0, size, frame.pixels);
      var length = decodePixels(input, width, height, output, _capacity);
      if (length == QR_DECODE_NOT_FOUND && useAdaptiveThreshold) {
        final cells = (width + 1) * (height + 1);
        if ((_integral?.length ?? 0) < cells) _integral = Uint32List(cells);
        final integral = _integral!;
        try {
          writeAdaptiveThreshold(
            frame.pixels,
            width,
            height,
            inputBytes,
            integral,
          );
        } finally {
          integral.fillRange(0, cells, 0);
        }
        length = decodePixels(input, width, height, output, _capacity);
      }
      return switch (length) {
        QR_DECODE_NOT_FOUND => null,
        QR_DECODE_INVALID_INPUT => throw StateError(
          'The decoder rejected the frame.',
        ),
        QR_DECODE_CAPACITY_EXCEEDED => throw StateError(
          'The decoded QR exceeds the output capacity.',
        ),
        QR_DECODE_PANIC => throw StateError('The native QR decoder failed.'),
        < 0 ||
        > _capacity => throw StateError('Unexpected QR decoder response.'),
        _ => _decodeText(Uint8List.sublistView(outputBytes, 0, length)),
      };
    } finally {
      inputBytes.fillRange(0, size, 0);
      outputBytes.fillRange(0, _capacity, 0);
    }
  }

  static String _decodeText(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('QR payload is not valid UTF-8.');
    }
  }

  void dispose() {
    final input = _input;
    final output = _output;
    _input = null;
    _inputCapacity = 0;
    _output = null;
    _integral = null;
    if (input != null) _allocator.free(input);
    if (output != null) _allocator.free(output);
  }
}
