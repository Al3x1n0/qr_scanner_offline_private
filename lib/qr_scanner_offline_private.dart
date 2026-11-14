/// Experimental offline QR scanner components for Android and iOS.
library;

export 'src/contrast.dart' show adaptiveThreshold;
export 'src/decoder.dart' show Frame, lumaFrame, decodeFrame;
export 'src/scanner_view.dart'
    show OfflineQrScanner, OfflineQrScannerController;

export 'package:camera/camera.dart' show CameraLensDirection, ResolutionPreset;
