# QR Scanner Offline Private

An experimental Flutter package for scanning QR codes locally on Android and
iOS. It uses the Flutter `camera` plugin and a precompiled Rust decoder. Only
QR codes are supported, not other barcode formats.

**Alpha:** this package is not production ready. A previous report of rapid
Android storage growth did not recur during a subsequent debug test on one
device. The original cause remains unknown. Earlier builds were tested on
Android and iOS. Storage use and compatibility can vary across devices and
builds.

## Requirements

- Dart `>=3.14.0 <4.0.0` and Flutter `>=3.50.0`. Your Flutter installation
  must include a compatible Dart SDK.
- Android API 24 or later; bundled architectures: arm, arm64, and x64.
- iOS: the resolved camera implementation requires iOS 13 or later; the bundled
  arm64 simulator decoder requires iOS 14 or later. Flutter 3.50 requires iOS
  15 or later. Bundled architectures are
  arm64 for devices and arm64/x64 for simulators.
- A camera and camera permission. A simulator build does not establish that
  scanning works on a physical device.

This version uses `material_ui` and requires the host app to migrate its Material
widgets to that package. This is a breaking change from 0.1.x; see the
[Flutter migration guide](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui).
The development SDK is pinned to Flutter 3.50.0 using FVM.

The package bundles its native decoder; Rust is not required to build a host
app for the supported targets. Other platforms and architectures are not
supported. The actual minimums can also be affected by the versions of the
host application's other dependencies.

## Install

Add the package to your Flutter app's `pubspec.yaml` after the version is
published:

```yaml
dependencies:
  flutter:
    sdk: flutter
  qr_scanner_offline_private: 0.2.0-alpha.3
```

Then run `flutter pub get`. For local development before publication, replace
the version with a `path:` dependency pointing to your local package checkout.
Import the package in your Dart code:

```dart
import 'package:qr_scanner_offline_private/qr_scanner_offline_private.dart';
```

## Platform configuration

### Android

Set `minSdk` to at least 24 in `android/app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        minSdk = 24
    }
}
```

For a Groovy `build.gradle`, use `minSdk 24` instead. Add the camera permission
inside the root `<manifest>` element of `android/app/src/main/AndroidManifest.xml`,
before `<application>`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
```

The Android CameraX implementation can contribute `RECORD_AUDIO` and legacy
`WRITE_EXTERNAL_STORAGE` (through API 28), even though this scanner disables
audio. Other dependencies can contribute `READ_EXTERNAL_STORAGE`. If **no
other feature in your app** needs these permissions, remove them in the app
manifest. Add the `tools` namespace to the existing `<manifest>` tag
and add the following elements alongside the camera permission:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO"
        tools:node="remove" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
        tools:node="remove" />
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
        tools:node="remove" />
    <!-- Keep your existing application element here. -->
</manifest>
```

The final permissions depend on the app's entire dependency graph. Inspect the
merged manifest for the build variant you release and keep permissions needed
by your app's other features. For example, the resolved Android media
dependency can add `ACCESS_NETWORK_STATE`. See Android's
[manifest merger documentation](https://developer.android.com/build/manage-manifests).

### iOS

Add a camera usage description inside the existing `<dict>` in
`ios/Runner/Info.plist`. The text is shown to the user by iOS:

```xml
<key>NSCameraUsageDescription</key>
<string>We use the camera to scan QR codes.</string>
```

Set your app's iOS deployment target to at least the minimum required by your
resolved camera dependency, and to iOS 14 or later when building for an arm64
simulator. Check the target in Xcode and, if your app uses CocoaPods, its
`ios/Podfile`. Use a real iPhone or iPad to test the camera and permissions.

## Add a scanner screen

Run the [example app](example/README.md) on Android or iOS to try the scanner
with camera switching, torch, zoom, and duplicate filtering.

The following is a complete screen to add to an existing Flutter app. Open it
with `Navigator.push`, or use it as the app's home screen. It shows the latest
value and provides start, stop, torch and camera-switch controls. Replace the
result handling with your app's own behavior; QR content may be sensitive.

```dart
import 'package:material_ui/material_ui.dart';
import 'package:qr_scanner_offline_private/qr_scanner_offline_private.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final scanner = OfflineQrScannerController(
    duplicateFilterDuration: const Duration(seconds: 2),
  );
  String? result;
  String? error;

  @override
  void dispose() {
    scanner.dispose();
    super.dispose();
  }

  void showError(Object _) {
    if (!mounted) return;
    setState(() => error = 'Unable to operate the scanner.');
  }

  String displayText(String value) => value.replaceAllMapped(
    RegExp(r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]'),
    (match) => '\\u{${match.group(0)!.codeUnitAt(0).toRadixString(16)}}',
  );

  Future<void> runAction(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => error = null);
    } catch (value) {
      showError(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a QR code')),
      body: Column(
        children: [
          Expanded(
            child: OfflineQrScanner(
              controller: scanner,
              onDetected: (value) {
                if (mounted) setState(() => result = displayText(value));
              },
              onError: showError,
            ),
          ),
          if (result != null) Text('Result: $result'),
          if (error != null) Text(error!),
          AnimatedBuilder(
            animation: scanner,
            builder: (context, _) => Wrap(
              children: [
                TextButton(
                  onPressed: scanner.isRunning
                      ? () => runAction(scanner.stop)
                      : () => runAction(scanner.start),
                  child: Text(scanner.isRunning ? 'Stop' : 'Start'),
                ),
                TextButton(
                  onPressed: scanner.isRunning
                      ? () => runAction(scanner.toggleTorch)
                      : null,
                  child: Text(scanner.torchEnabled ? 'Torch off' : 'Torch on'),
                ),
                TextButton(
                  onPressed: scanner.isRunning
                      ? () => runAction(scanner.switchCamera)
                      : null,
                  child: const Text('Switch camera'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

The widget requests camera access as it initializes. The system can show its
permission prompt then. If access is denied or initialization fails, `onError`
receives the error; show an appropriate message and follow the platform's
permission recovery flow. The scanner shows a progress indicator while opening
the camera and a generic message when opening fails. Supply `loadingBuilder`
and `errorBuilder` to customize those views. The error builder also receives
the underlying startup error so the app can map known errors to localized text.

## Controller and lifecycle

A controller is optional. Without one, `OfflineQrScanner` creates and disposes
its own controller and starts automatically. With an external controller:

- Create it once in your `State`, attach it to at most one scanner at a time,
  and dispose it when no longer needed. Call its methods only while the widget
  is attached; otherwise they throw `StateError`.
- Set `autoStart: false` to wait for `await scanner.start()`. `stop()` releases
  the camera; `start()` requests it again. The widget keeps the session through
  transient `inactive` states, such as a system permission prompt. It releases
  the camera when the app is hidden, paused or detached, and resumes if
  scanning is still requested. Removing the widget also releases the camera.
- Choose the initial `facing` (`CameraLensDirection.back` by default) and
  `resolution` (`ResolutionPreset.medium` by default) when constructing the
  controller. Availability and supported resolutions depend on the device.
- `isRunning`, `torchEnabled`, `zoomScale` and `error` expose the current state
  or most recent error. The controller is a `ChangeNotifier`: use
  `AnimatedBuilder` or a listener to update your UI. An explicit `start()`
  clears the previous error when the request is processed. `stop()` retains
  the most recent error.
- `setTorch(bool)`, `toggleTorch()`, `switchCamera()`, `getZoomRange()` and
  `setZoomScale(double)` return futures. Catch errors such as unsupported
  hardware, an unavailable camera or an invalid zoom value. Torch, zoom and
  camera switching require a running camera.
- If replacing a controller on an existing scanner, give the scanner a new key.
  Do not dispose an externally owned controller while it is still in use.

For example, set a supported zoom while running:

```dart
try {
  final range = await scanner.getZoomRange();
  final zoom = 2.0.clamp(range.min, range.max).toDouble();
  await scanner.setZoomScale(zoom);
} catch (error) {
  // Show an appropriate error in your app.
}
```

`onDetected` receives decoded text. Alternatively, subscribe to the broadcast
stream `scanner.detections` and cancel your subscription when finished. Using
both reports the same detection through both channels. The default
`duplicateFilterDuration` is zero, so the same visible code can be reported on
successive frames. Set a positive duration to suppress consecutive reports of
the same value within that interval. A different value is reported immediately.
Stopping the session resets this filter.

## Preview and overlay

Give the scanner bounded dimensions, for example with `Expanded`, `SizedBox`
or `AspectRatio`. `fit: BoxFit.cover` fills the area and can crop the preview.
`BoxFit.contain` fits the full preview within it. By default the decoder
analyzes the full stream frame, including parts that may be outside the visible
preview. The overlay controls the display only.

Set `frameRegion` to crop the stream pixels before decoding. For example,
`Rect.fromLTRB(0.25, 0.25, 0.75, 0.75)` scans the central half of the frame in
each dimension. Coordinates run from 0 to 1 from the top left of the **raw
stream frame**. Preview fitting, rotation, mirroring and the camera plugin's
separate preview stream can affect which of those pixels are displayed. An
overlay drawn in widget coordinates does not define the decoding region.

```dart
AspectRatio(
  aspectRatio: 1,
  child: OfflineQrScanner(
    fit: BoxFit.cover,
    overlay: IgnorePointer(
      child: Center(
        child: SizedBox.square(
          dimension: 200,
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: Colors.white)),
          ),
        ),
      ),
    ),
    onDetected: (value) {
      // Handle the decoded text.
    },
    onError: (error) {
      // Show an appropriate error.
    },
  ),
)
```

Camera zoom changes the frame delivered to the decoder, subject to device
support; an overlay alone does not restrict the decoded region.

## Advanced: decode a frame

Most apps should use the widget. The package also exports `Frame`, `lumaFrame`,
`decodeFrame` and `adaptiveThreshold` for apps managing their own camera stream.
`lumaFrame` accepts a `CameraImage` in YUV420 or BGRA8888 format and copies its
luminance into a `Frame`. `Frame` holds a `Uint8List` of exactly `width * height`
8-bit luminance values in row-major order. Input is limited to 8,294,400 pixels
(3840 × 2160). `decodeFrame(frame)` returns UTF-8 text or `null` if no
supported text code is found. Empty payloads and invalid UTF-8 are
skipped. A miss triggers a retry with adaptive thresholding. The widget runs
these retries on alternate frames in a background isolate. `decodeFrame` is
synchronous and can throw for invalid input, decoder failures or unsupported
platforms. Manage camera lifecycle, frame scheduling, errors and disposal of
the input buffer when using it directly. `adaptiveThreshold` returns a new
buffer and accepts optional `radius` (at least 1, default 16) and `offset`
(nonnegative, default 3).

## Privacy and licensing

The scanner is designed to process frames locally without sending QR content,
images, usage metrics or analytics over the network. This is not an independent
certification of the dependency graph or the host app. Avoid logging or storing
QR content unless your app explicitly needs it. The scanner clears its own
mutable temporary buffers after use. The camera plugin and Rust decoding
dependency manage their own intermediate buffers. Strings returned to the
host app are immutable and cannot be reliably erased from managed memory.

Treat every decoded value as untrusted input. The example escapes control
characters and bidirectional formatting marks such as `U+202E` for display.
Validate the original value for its intended use. Before opening a QR as a
link, parse it and allow only the URI schemes and destinations your app
expects. Avoid logging raw QR values or displaying exception details to users.

The package's own code is GPL-3.0-only; see [LICENSE](LICENSE). Third-party
components retain their own licenses and attribution requirements; see
[THIRD_PARTY.md](THIRD_PARTY.md). Review the license obligations for your app
and its separately resolved dependencies before distributing it.

## Acknowledgments

Thanks to [@Daveide90](https://github.com/Daveide90) for contributing to this project.
