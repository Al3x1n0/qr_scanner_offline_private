import 'dart:math' as math;
import 'dart:typed_data';

// UHD 4K. Also bounds the size and maximum sum of the integral image.
const maxFramePixels = 3840 * 2160;

void validateFrameDimensions(int width, int height) {
  if (width <= 0 || height <= 0 || height > maxFramePixels ~/ width) {
    throw ArgumentError('Invalid or unsupported frame dimensions.');
  }
}

/// Adaptive threshold using a local mean, returning an independent luma buffer.
Uint8List adaptiveThreshold(
  Uint8List pixels,
  int width,
  int height, {
  int radius = 16,
  int offset = 3,
}) {
  validateFrameDimensions(width, height);
  if (pixels.length != width * height || radius < 1 || offset < 0) {
    throw ArgumentError('Invalid image size or threshold parameters.');
  }
  final result = Uint8List(pixels.length);
  final integral = Uint32List((width + 1) * (height + 1));
  try {
    writeAdaptiveThreshold(
      pixels,
      width,
      height,
      result,
      integral,
      radius: radius,
      offset: offset,
    );
    return result;
  } finally {
    integral.fillRange(0, integral.length, 0);
  }
}

// The caller supplies correctly sized output and zeroed scratch space.
void writeAdaptiveThreshold(
  Uint8List pixels,
  int width,
  int height,
  Uint8List result,
  Uint32List integral, {
  int radius = 16,
  int offset = 3,
}) {
  final windowRadius = math.min(radius, math.max(width, height));
  final brightnessOffset = math.min(offset, 255);
  final stride = width + 1;
  for (var y = 0; y < height; y++) {
    var rowSum = 0;
    for (var x = 0; x < width; x++) {
      rowSum += pixels[y * width + x];
      integral[(y + 1) * stride + x + 1] =
          integral[y * stride + x + 1] + rowSum;
    }
  }
  for (var y = 0; y < height; y++) {
    final top = math.max(0, y - windowRadius);
    final bottom = math.min(height, y + windowRadius + 1);
    for (var x = 0; x < width; x++) {
      final left = math.max(0, x - windowRadius);
      final right = math.min(width, x + windowRadius + 1);
      final sum =
          integral[bottom * stride + right] -
          integral[top * stride + right] -
          integral[bottom * stride + left] +
          integral[top * stride + left];
      final count = (right - left) * (bottom - top);
      result[y * width +
          x] = pixels[y * width + x] * count < sum - brightnessOffset * count
          ? 0
          : 255;
    }
  }
}
