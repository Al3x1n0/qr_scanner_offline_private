## 0.1.0-alpha.1 (unreleased)

- Initial experimental frame conversion, Rust QR decoder source, and low-contrast retry.
- Android prototype tested on one device; package integration is not yet complete.
- Added an experimental camera widget and native decoder for Android and iOS.
- Bundled experimental Android and iOS decoder binaries so supported mobile
  builds do not require Rust; release and license verification is ongoing.
- Added a scanner controller with camera start and stop, torch, camera
  switching, zoom, detection stream and duplicate filtering.
- Added configurable preview fitting and an overlay, plus interactive example
  controls. The preview crop does not restrict the decoded region.
- A previous report of rapid Android storage growth did not recur in a
  subsequent debug test on one device; the original cause remains unknown.

- Stop automatic camera retries after a startup error and report the failure;
  scanning can be restarted after camera access is restored.
