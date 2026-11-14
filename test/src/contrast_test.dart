import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr_scanner_offline_private/src/contrast.dart';

void main() {
  group('Soglia locale', () {
    test('distingue un dettaglio scuro a basso contrasto', () {
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
    test('un campo uniforme non produce un falso dettaglio', () {
      expect(
        adaptiveThreshold(Uint8List(9)..fillRange(0, 9, 100), 3, 3),
        everyElement(255),
      );
    });
    test('rifiuta dimensioni incoerenti', () {
      expect(() => adaptiveThreshold(Uint8List(3), 2, 2), throwsArgumentError);
    });
  });
}
