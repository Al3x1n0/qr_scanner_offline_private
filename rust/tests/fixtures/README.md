`zxing-qrcode-6-7.rle` contains 500 × 500 grayscale pixels derived from
ZXing's `core/src/test/resources/blackbox/qrcode-6/7.png`:
https://github.com/zxing/zxing/blob/master/core/src/test/resources/blackbox/qrcode-6/7.png

Original PNG SHA-256: c32be7f134a927159edceb63eec1c7ed186823c2dfeea71db184ce414790a941.
ZXing is Copyright 2007 ZXing authors and licensed under Apache License 2.0;
the license text is included as `LICENSE-APACHE`. The image was converted to RGB and then grayscale; the
result is encoded as runs of one pixel value followed by a little-endian u16
count. This derived fixture is used only for regression testing.

`utf8-qr.txt`, `binary-qr.txt` and `empty-qr.txt` are synthetic QR module grids
generated with the Dart `qr` 3.0.2 encoder at error correction level M. The
payloads are the UTF-8 bytes for `Café QR`, the bytes `00 80 ff`, and an empty
byte sequence respectively. `#` represents a dark module and `.` a light
module. The tests add a quiet zone and render each module as a pixel square.
