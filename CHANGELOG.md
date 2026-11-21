## 0.2.0-alpha.2

- Update the bundled QR decoder to `rqrr` 0.11.0 with `lru` 0.18.5, which includes the fix for [RUSTSEC-2026-0253](https://rustsec.org/advisories/RUSTSEC-2026-0253.html).

## 0.2.0-alpha.1

- Breaking: migrate scanner widgets to `material_ui`; host apps must migrate
  their Material widgets. The minimum versions are Flutter 3.50.0 and Dart
  3.14.0.
- Update camera to 0.12.2 and use its current Android and iOS implementations.
- Pin development to Flutter 3.50.0 via FVM and update the FFI generator.

- Contain Rust decoder panics at the FFI boundary and report a decoder error.
- Clarify that codes outside a cropped preview can still be returned.

## 0.1.0-alpha.1

- Initial experimental frame conversion, Rust QR decoder source, and low-contrast retry.
- Tested scanning on one Android device and one iPad.
- Added an experimental camera widget and native decoder for Android and iOS.
- Bundled experimental Android and iOS decoder binaries so supported mobile
  builds do not require Rust. See THIRD_PARTY.md for license information and
  remaining limitations.
- Added a scanner controller with camera start and stop, torch, camera
  switching, zoom, detection stream and duplicate filtering.
- Added configurable preview fitting and an overlay, plus interactive example
  controls. The preview crop does not restrict the decoded region.
- A previous report of rapid Android storage growth did not recur in a
  subsequent debug test on one device; the original cause remains unknown.
- Stop automatic camera retries after a startup error and report the failure;
  scanning can be restarted after camera access is restored.
