import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'contrast.dart';
import 'qr_decoder.g.dart';

class Frame {
  const Frame(this.pixels, this.width, this.height);
  final Uint8List pixels;
  final int width;
  final int height;
}

// A single luma plane is enough for decoding. Account for row padding.
Frame lumaFrame(CameraImage image) {
  if (image.planes.isEmpty || image.width <= 0 || image.height <= 0) {
    throw ArgumentError('Invalid camera image.');
  }
  final bgra = image.format.group == ImageFormatGroup.bgra8888;
  if (!bgra && image.format.group != ImageFormatGroup.yuv420) {
    throw UnsupportedError('Unsupported camera image format.');
  }
  final plane = image.planes.first;
  final output = Uint8List(image.width * image.height);
  final pixelStride = plane.bytesPerPixel ?? (bgra ? 4 : 1);
  final lastByte =
      (image.height - 1) * plane.bytesPerRow +
      (image.width - 1) * pixelStride +
      (bgra ? 2 : 0);
  if (pixelStride <= 0 ||
      plane.bytesPerRow <= 0 ||
      lastByte >= plane.bytes.length) {
    throw ArgumentError('Invalid camera image plane.');
  }
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final i = y * plane.bytesPerRow + x * pixelStride;
      if (bgra) {
        final b = plane.bytes[i],
            g = plane.bytes[i + 1],
            r = plane.bytes[i + 2];
        output[y * image.width + x] = (r * 77 + g * 150 + b * 29) >> 8;
      } else {
        output[y * image.width + x] = plane.bytes[i];
      }
    }
  }
  return Frame(output, image.width, image.height);
}

String? decodeFrame(Frame frame) {
  if (!Platform.isAndroid && !Platform.isIOS) {
    throw UnsupportedError('Decoder non disponibile su questa piattaforma.');
  }
  if (frame.width <= 0 ||
      frame.height <= 0 ||
      frame.width > 0xffffffff ||
      frame.height > 0xffffffff ||
      frame.pixels.length != frame.width * frame.height) {
    throw ArgumentError('Dimensioni del frame non valide.');
  }
  final input = malloc<Uint8>(frame.pixels.length);
  const capacity = 16384;
  final output = malloc<Uint8>(capacity);
  try {
    input.asTypedList(frame.pixels.length).setAll(0, frame.pixels);
    var length = qr_decode(input, frame.width, frame.height, output, capacity);
    if (length == 0) {
      final enhanced = adaptiveThreshold(
        frame.pixels,
        frame.width,
        frame.height,
      );
      try {
        input.asTypedList(enhanced.length).setAll(0, enhanced);
        length = qr_decode(input, frame.width, frame.height, output, capacity);
      } finally {
        enhanced.fillRange(0, enhanced.length, 0);
      }
    }
    if (length < 0) throw StateError('Errore del decoder ($length)');
    if (length == 0) return null;
    return utf8.decode(output.asTypedList(length), allowMalformed: false);
  } finally {
    input.asTypedList(frame.pixels.length).fillRange(0, frame.pixels.length, 0);
    output.asTypedList(capacity).fillRange(0, capacity, 0);
    malloc.free(input);
    malloc.free(output);
  }
}
