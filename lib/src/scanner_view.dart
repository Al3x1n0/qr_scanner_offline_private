import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'decoder.dart';

/// Controls the camera session attached to an [OfflineQrScanner].
///
/// Attach a controller to at most one widget and dispose it when no longer used.
class OfflineQrScannerController extends ChangeNotifier {
  /// Creates a scanner controller.
  OfflineQrScannerController({
    this.autoStart = true,
    this.facing = CameraLensDirection.back,
    this.resolution = ResolutionPreset.medium,
    Duration duplicateFilterDuration = Duration.zero,
  }) : assert(!duplicateFilterDuration.isNegative),
       _duplicateFilterDuration = duplicateFilterDuration;

  /// Whether the camera starts when the widget is mounted.
  final bool autoStart;

  /// The preferred camera direction.
  final CameraLensDirection facing;

  /// The requested camera resolution.
  final ResolutionPreset resolution;

  /// The minimum time between consecutive reports of the same value.
  Duration get duplicateFilterDuration => _duplicateFilterDuration;
  Duration _duplicateFilterDuration;

  set duplicateFilterDuration(Duration value) {
    if (value.isNegative) throw ArgumentError.value(value);
    _duplicateFilterDuration = value;
    if (!_disposed) notifyListeners();
  }

  _OfflineQrScannerState? _state;
  bool _disposed = false;
  bool _running = false;
  bool _torchEnabled = false;
  double _zoomScale = 1;
  Object? _error;
  final StreamController<String> _detections = StreamController.broadcast();

  /// The stream of decoded QR values.
  Stream<String> get detections => _detections.stream;

  /// Whether the camera is streaming frames.
  bool get isRunning => _running;

  /// Whether the torch was enabled through this controller.
  bool get torchEnabled => _torchEnabled;

  /// The last zoom scale set through this controller.
  double get zoomScale => _zoomScale;

  /// The most recent scanner error, or `null` if no error was reported.
  Object? get error => _error;

  _OfflineQrScannerState get _attached {
    if (_disposed || _state == null) {
      throw StateError('The controller is not attached to an active scanner.');
    }
    return _state!;
  }

  /// Starts or resumes scanning.
  Future<void> start() => _attached._startRequested();

  /// Stops scanning and releases the camera.
  Future<void> stop() => _attached._stopRequested();

  /// Enables or disables the camera torch.
  ///
  /// The camera must be running. A stopped scanner releases the camera.
  Future<void> setTorch(bool enabled) => _attached._setTorch(enabled);

  /// Toggles the camera torch.
  Future<void> toggleTorch() => setTorch(!torchEnabled);

  /// Switches between the front and back cameras when available.
  Future<void> switchCamera() => _attached._switchCamera();

  /// Returns the supported zoom range for the active camera.
  Future<({double min, double max})> getZoomRange() =>
      _attached._getZoomRange();

  /// Sets the active camera's zoom scale.
  Future<void> setZoomScale(double scale) => _attached._setZoomScale(scale);

  void _update({bool? running, bool? torch, double? zoom}) {
    if (_disposed) return;
    _running = running ?? _running;
    _torchEnabled = torch ?? _torchEnabled;
    _zoomScale = zoom ?? _zoomScale;
    notifyListeners();
  }

  void _reportError(Object error) {
    if (_disposed) return;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _detections.close();
    super.dispose();
  }
}

/// Experimental camera preview that reports decoded QR text.
class OfflineQrScanner extends StatefulWidget {
  const OfflineQrScanner({
    super.key,
    this.onDetected,
    this.onError,
    this.controller,
    this.fit = BoxFit.cover,
    this.overlay,
  });

  /// Called when a QR code is decoded.
  final ValueChanged<String>? onDetected;

  /// Called when initialization or decoding fails.
  final ValueChanged<Object>? onError;

  /// The optional controller used to operate this scanner.
  final OfflineQrScannerController? controller;

  /// How the preview fits its available space.
  ///
  /// This changes only the preview, not the portion of each frame decoded.
  final BoxFit fit;

  /// A widget drawn above the camera preview.
  final Widget? overlay;

  @override
  State<OfflineQrScanner> createState() => _OfflineQrScannerState();
}

class _OfflineQrScannerState extends State<OfflineQrScanner>
    with WidgetsBindingObserver {
  CameraController? _camera;
  Future<void> _operation = Future<void>.value();
  bool _active = true;
  bool _closed = false;
  bool _decoding = false;
  int _generation = 0;
  late OfflineQrScannerController _controller;
  late bool _ownsController;
  late bool _requested;
  late CameraLensDirection _facing;
  String? _lastValue;
  DateTime? _lastDetection;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? OfflineQrScannerController();
    if (_controller._state != null || _controller._disposed) {
      throw StateError('A scanner controller can only be attached once.');
    }
    _controller._state = this;
    _requested = _controller.autoStart;
    _facing = _controller.facing;
    WidgetsBinding.instance.addObserver(this);
    if (_requested) _runAutomatically(_start);
  }

  @override
  void didUpdateWidget(covariant OfflineQrScanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      throw StateError('Use a new widget key when changing controllers.');
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operation.then((_) => operation());
    _operation = next.catchError((Object error) {
      if (!_closed) {
        _controller._reportError(error);
        widget.onError?.call(error);
      }
    });
    return next;
  }

  void _runAutomatically(Future<void> Function() operation) {
    unawaited(_enqueue(operation).catchError((Object _) {}));
  }

  Future<void> _startRequested() {
    _controller._error = null;
    if (mounted) setState(() {});
    _requested = true;
    return _enqueue(_start);
  }

  Future<void> _stopRequested() {
    _requested = false;
    ++_generation;
    return _enqueue(_stop);
  }

  Future<void> _setTorch(bool enabled) => _enqueue(() async {
    final camera = _camera;
    if (camera == null) throw StateError('The camera is not running.');
    await camera.setFlashMode(enabled ? FlashMode.torch : FlashMode.off);
    _controller._update(torch: enabled);
  });

  Future<void> _switchCamera() => _enqueue(() async {
    final target = _facing == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final cameras = await availableCameras();
    if (!cameras.any((camera) => camera.lensDirection == target)) {
      throw StateError('The requested camera is not available.');
    }
    _facing = target;
    await _stop();
    await _start();
  });

  Future<({double min, double max})> _getZoomRange() async {
    final camera = _camera;
    if (camera == null) throw StateError('The camera is not running.');
    return (
      min: await camera.getMinZoomLevel(),
      max: await camera.getMaxZoomLevel(),
    );
  }

  Future<void> _setZoomScale(double scale) => _enqueue(() async {
    final camera = _camera;
    if (camera == null) throw StateError('The camera is not running.');
    final min = await camera.getMinZoomLevel();
    final max = await camera.getMaxZoomLevel();
    if (!scale.isFinite || scale < min || scale > max) {
      throw ArgumentError.value(
        scale,
        'scale',
        'Must be between $min and $max.',
      );
    }
    await camera.setZoomLevel(scale);
    _controller._update(zoom: scale);
  });

  Future<void> _start() async {
    try {
      await _startCamera();
    } catch (_) {
      _requested = false;
      if (mounted && !_closed) setState(() {});
      rethrow;
    }
  }

  Future<void> _startCamera() async {
    if (_closed || !_active || !_requested || _camera != null) return;
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError('Only Android and iOS are supported.');
    }
    final cameras = await availableCameras();
    if (_closed || !_active || !_requested) return;
    if (cameras.isEmpty) throw StateError('No camera is available.');
    final camera = CameraController(
      cameras.firstWhere(
        (camera) => camera.lensDirection == _facing,
        orElse: () => cameras.first,
      ),
      _controller.resolution,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    try {
      await camera.initialize();
      if (_closed || !_active || !_requested) {
        await camera.dispose();
        return;
      }
      _camera = camera;
      final generation = ++_generation;
      await camera.startImageStream((image) => _onFrame(image, generation));
      _controller._update(running: true);
      if (mounted) setState(() {});
    } catch (_) {
      _camera = null;
      await camera.dispose();
      rethrow;
    }
  }

  Future<void> _onFrame(CameraImage image, int generation) async {
    if (_decoding || _closed || !_active) return;
    _decoding = true;
    try {
      final frame = lumaFrame(image);
      try {
        final result = await compute(decodeFrame, frame);
        if (!_closed &&
            _active &&
            generation == _generation &&
            result != null) {
          final now = DateTime.now();
          if (_lastValue != result ||
              _lastDetection == null ||
              now.difference(_lastDetection!) >=
                  _controller.duplicateFilterDuration) {
            _lastValue = result;
            _lastDetection = now;
            if (!_controller._disposed) _controller._detections.add(result);
            widget.onDetected?.call(result);
          }
        }
      } finally {
        frame.pixels.fillRange(0, frame.pixels.length, 0);
      }
    } catch (error) {
      if (!_closed && _active && generation == _generation) {
        _controller._reportError(error);
        widget.onError?.call(error);
      }
    } finally {
      _decoding = false;
    }
  }

  Future<void> _stop() async {
    ++_generation;
    final camera = _camera;
    _camera = null;
    _controller._update(running: false, torch: false, zoom: 1);
    if (mounted && !_closed) setState(() {});
    await camera?.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) ++_generation;
    _runAutomatically(_active && _requested ? _start : _stop);
  }

  @override
  void dispose() {
    _closed = true;
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _runAutomatically(_stop);
    _controller._state = null;
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      if (_controller.error != null) {
        return const Center(
          child: Text(
            'Camera unavailable',
            style: TextStyle(color: Colors.white),
          ),
        );
      }
      if (!_requested) return const SizedBox.shrink();
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return CameraPreview(camera, child: widget.overlay);
        }
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder<CameraValue>(
                valueListenable: camera,
                builder: (context, value, _) {
                  final orientation =
                      value.previewPauseOrientation ??
                      value.lockedCaptureOrientation ??
                      value.deviceOrientation;
                  final landscape =
                      orientation == DeviceOrientation.landscapeLeft ||
                      orientation == DeviceOrientation.landscapeRight;
                  final ratio = landscape
                      ? value.aspectRatio
                      : 1 / value.aspectRatio;
                  return FittedBox(
                    fit: widget.fit,
                    child: SizedBox(
                      width: ratio * 1000,
                      height: 1000,
                      child: CameraPreview(camera),
                    ),
                  );
                },
              ),
              if (widget.overlay != null) widget.overlay!,
            ],
          ),
        );
      },
    );
  }
}
