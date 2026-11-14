import 'dart:typed_data';

/// Adaptive threshold using a local mean; returns an independent luma buffer.
Uint8List adaptiveThreshold(
  Uint8List pixels,
  int width,
  int height, {
  int radius = 16,
  int offset = 3,
}) {
  if (width <= 0 ||
      height <= 0 ||
      pixels.length != width * height ||
      radius < 1 ||
      offset < 0) {
    throw ArgumentError('Invalid image dimensions or threshold parameters');
  }
  final stride = width + 1;
  final integral = Int64List((width + 1) * (height + 1));
  for (var y = 0; y < height; y++) {
    var rowSum = 0;
    for (var x = 0; x < width; x++) {
      rowSum += pixels[y * width + x];
      integral[(y + 1) * stride + x + 1] =
          integral[y * stride + x + 1] + rowSum;
    }
  }
  final result = Uint8List(pixels.length);
  for (var y = 0; y < height; y++) {
    final top = (y - radius).clamp(0, height);
    final bottom = (y + radius + 1).clamp(0, height);
    for (var x = 0; x < width; x++) {
      final left = (x - radius).clamp(0, width);
      final right = (x + radius + 1).clamp(0, width);
      final sum =
          integral[bottom * stride + right] -
          integral[top * stride + right] -
          integral[bottom * stride + left] +
          integral[top * stride + left];
      final count = (right - left) * (bottom - top);
      result[y * width + x] =
          pixels[y * width + x] * count < sum - offset * count ? 0 : 255;
    }
  }
  return result;
}
