import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr_scanner_offline_private/src/contrast.dart';

void main() {
  group('Adaptive threshold', () {
    test('distinguishes a dark low-contrast detail', () {
      final pixels = Uint8List.fromList([
        100,
        100,
        100,
        100,
        90,
        100,
        100,
        100,
        100,
      ]);
      final result = adaptiveThreshold(pixels, 3, 3, radius: 1, offset: 3);
      expect(result[4], 0);
      expect(result[0], 255);
      expect(pixels[4], 90);
    });

    test('keeps a uniform frame white', () {
      expect(
        adaptiveThreshold(Uint8List(9)..fillRange(0, 9, 100), 3, 3),
        everyElement(255),
      );
    });

    test('clamps a large radius to the bounds of a rectangular frame', () {
      final pixels = Uint8List.fromList([2, 3, 4, 5, 6, 7]);
      expect(
        adaptiveThreshold(pixels, 3, 2, radius: 999, offset: 0),
        orderedEquals([0, 0, 0, 255, 255, 255]),
      );
    });

    test('rejects invalid dimensions and parameters before allocating', () {
      expect(() => adaptiveThreshold(Uint8List(3), 2, 2), throwsArgumentError);
      expect(() => adaptiveThreshold(Uint8List(0), 0, 2), throwsArgumentError);
      expect(
        () => adaptiveThreshold(Uint8List(1), 1, 1, radius: 0),
        throwsArgumentError,
      );
      expect(
        () => adaptiveThreshold(Uint8List(1), 1, 1, offset: -1),
        throwsArgumentError,
      );
      expect(
        () => adaptiveThreshold(Uint8List(0), maxFramePixels + 1, 1),
        throwsArgumentError,
      );
    });
  });
}
