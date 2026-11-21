# QR Scanner Offline Private example

A Flutter app for trying the QR scanner on Android and iOS. It demonstrates
camera switching, torch and zoom controls, preview fitting and duplicate
filtering. It displays the latest result as text.

From the package root, with Flutter 3.50.0 or later and a connected Android or
iOS device, run:

```sh
cd example
flutter pub get
flutter run
```

The app imports the package from the parent directory. Android needs a device
running API 24 or later. On iOS, Flutter requires iOS 15 or later. Grant camera
access when prompted.

For an iOS device build, configure your own development team. You can put
`DEVELOPMENT_TEAM = YOUR_TEAM_ID` in `ios/Flutter/LocalSigning.xcconfig`, which
the project includes when present and Git ignores. If you need a unique bundle
identifier, configure it locally for the Runner target in Xcode. Use
`flutter build ios --debug --no-codesign` to compile without signing.
