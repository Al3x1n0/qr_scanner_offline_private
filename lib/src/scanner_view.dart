import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'decoder.dart' show validateFrameRegion;
import 'frame_worker.dart';

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

  OfflineQrScannerState? _state;
  bool _disposed = false;
  bool _running = false;
  bool _torchEnabled = false;
  double _zoomScale = 1;
  Object? _error;
  final StreamController<String> _detections = StreamController.broadcast();

  /// The stream of decoded QR values.
  Stream<String> get detections => _detections.stream;

  /// Whether a camera session is running, including during a camera switch.
  bool get isRunning => _running;

  /// Whether the torch was enabled through this controller.
  bool get torchEnabled => _torchEnabled;

  /// The last zoom scale set through this controller.
  double get zoomScale => _zoomScale;

  /// The most recent scanner error. An explicit [start] clears it.
  Object? get error => _error;

  OfflineQrScannerState get _attached {
    if (_disposed || _state == null) {
      throw StateError('The controller is not attached to an active scanner.');
    }
    return _state!;
  }

  /// Clears the previous error and requests scanning.
  Future<void> start() => _attached._startRequested();

  /// Stops scanning and releases the camera.
  Future<void> stop() => _attached._stopRequested();

  /// Enables or disables the camera torch.
  ///
  /// The camera must be running. A stopped scanner releases the camera.
  Future<void> setTorch(bool enabled) => _attached._setTorch(enabled);

  /// Toggles the camera torch.
  Future<void> toggleTorch() => setTorch(!torchEnabled);

  /// Switches between the front and back cameras during an active session.
  Future<void> switchCamera() => _attached._switchCamera();

  /// Returns the supported zoom range for the active camera.
  Future<({double min, double max})> getZoomRange() =>
      _attached._getZoomRange();

  /// Sets the active camera's zoom scale.
  Future<void> setZoomScale(double scale) => _attached._setZoomScale(scale);

  void _update({bool? running, bool? torch, double? zoom}) {
    if (_disposed) return;
    final nextRunning = running ?? _running;
    final nextTorch = torch ?? _torchEnabled;
    final nextZoom = zoom ?? _zoomScale;
    if (nextRunning == _running &&
        nextTorch == _torchEnabled &&
        nextZoom == _zoomScale) {
      return;
    }
    _running = nextRunning;
    _torchEnabled = nextTorch;
    _zoomScale = nextZoom;
    notifyListeners();
  }

  void _setError(Object? error) {
    if (_disposed || identical(_error, error)) return;
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
    this.errorBuilder,
    this.loadingBuilder,
    this.frameRegion,
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

  /// Builds the placeholder when the camera is unavailable after an error.
  final Widget Function(BuildContext, Object)? errorBuilder;

  /// Builds the placeholder while a camera session is requested.
  final WidgetBuilder? loadingBuilder;

  /// The region decoded, in normalized coordinates of the raw camera frame.
  ///
  /// Coordinates run from 0 to 1 from the top left of the frame raster. The
  /// preview's rotation, mirroring, and fit do not affect these coordinates.
  /// A null region decodes the full frame.
  final Rect? frameRegion;

  @override
  State<OfflineQrScanner> createState() => OfflineQrScannerState();
}

class OfflineQrScannerState extends State<OfflineQrScanner>
    with WidgetsBindingObserver {
  OfflineQrScannerState()
    : _platform = Platform.isAndroid
          ? TargetPlatform.android
          : Platform.isIOS
          ? TargetPlatform.iOS
          : null,
      _startWorker = FrameWorker.start;

  @visibleForTesting
  OfflineQrScannerState.testing(this._platform, this._startWorker);

  static const _frameErrorInterval = Duration(seconds: 1);
  final TargetPlatform? _platform;
  final Future<FrameWorker> Function() _startWorker;
  CameraController? _camera;
  FrameWorker? _worker;
  Future<void> _operation = Future<void>.value();
  late bool _active;
  bool _closed = false;
  bool _decoding = false;
  bool _switching = false;
  int _generation = 0;
  int _requestRevision = 0;
  late OfflineQrScannerController _controller;
  late bool _ownsController;
  late bool _requested;
  late CameraLensDirection _facing;
  String? _lastValue;
  DateTime? _lastDetection;
  DateTime? _lastFrameError;

  @override
  void initState() {
    super.initState();
    validateFrameRegion(widget.frameRegion);
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? OfflineQrScannerController();
    if (_controller._state != null || _controller._disposed) {
      throw StateError('A scanner controller can only be attached once.');
    }
    _controller._state = this;
    _requested = _controller.autoStart;
    _facing = _controller.facing;
    final binding = WidgetsBinding.instance;
    _active =
        binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    binding.addObserver(this);
    if (_requested) _runAutomatically(_start);
  }

  @override
  void didUpdateWidget(covariant OfflineQrScanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      throw StateError('Use a new widget key when changing controllers.');
    }
    if (oldWidget.frameRegion != widget.frameRegion) {
      validateFrameRegion(widget.frameRegion);
      _resetFrameHistory();
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _operation.then((_) async {
      try {
        return await operation();
      } catch (error) {
        if (!_closed) _reportError(error);
        rethrow;
      }
    });
    _operation = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  void _reportError(Object error) {
    _controller._setError(error);
    if (mounted && !_closed && _camera == null) setState(() {});
    widget.onError?.call(error);
  }

  void _runAutomatically(Future<void> Function() operation) {
    unawaited(_enqueue(operation).catchError((Object _) {}));
  }

  Future<void> _startRequested() {
    _requested = true;
    final revision = ++_requestRevision;
    return _enqueue(() async {
      if (_closed || revision != _requestRevision) return;
      _controller._setError(null);
      if (mounted) setState(() {});
      await _start();
    });
  }

  Future<void> _stopRequested() {
    _requested = false;
    ++_requestRevision;
    ++_generation;
    return _enqueue(_stop);
  }

  bool get _canStart => !_closed && _active && _requested;

  bool _isCurrent(int generation) => _canStart && generation == _generation;

  CameraController get _runningCamera {
    final camera = _camera;
    if (!_canStart || camera == null) {
      throw StateError('The camera is not running.');
    }
    return camera;
  }

  Future<void> _setTorch(bool enabled) => _enqueue(() async {
    await _runningCamera.setFlashMode(
      enabled ? FlashMode.torch : FlashMode.off,
    );
    _controller._update(torch: enabled);
  });

  Future<void> _switchCamera() => _enqueue(() async {
    final previous = _runningCamera;
    final target =
        previous.description.lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final previousGeneration = _generation;
    final cameras = await availableCameras();
    if (!_isCurrent(previousGeneration)) return;
    final description = cameras.firstWhere(
      (camera) => camera.lensDirection == target,
      orElse: () => throw StateError('The requested camera is not available.'),
    );
    final worker = _worker!;
    final generation = ++_generation;
    final revision = _requestRevision;
    _camera = null;
    _switching = true;
    _resetFrameHistory();
    if (mounted) setState(() {});
    try {
      await _releaseCamera(previous);
      if (!_isCurrent(generation)) return;
      final camera = await _openCamera(description, generation, worker);
      if (camera != null) {
        _camera = camera;
        _facing = target;
        _controller._update(torch: false, zoom: 1);
      }
    } catch (_) {
      if (!_isCurrent(generation)) return;
      if (revision == _requestRevision) _requested = false;
      rethrow;
    } finally {
      _switching = false;
      if (_camera == null) {
        await _stop();
      } else if (mounted && !_closed) {
        setState(() {});
      }
    }
  });

  Future<({double min, double max})> _getZoomRange() => _enqueue(() async {
    final camera = _runningCamera;
    return (
      min: await camera.getMinZoomLevel(),
      max: await camera.getMaxZoomLevel(),
    );
  });

  Future<void> _setZoomScale(double scale) => _enqueue(() async {
    final camera = _runningCamera;
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
    if (!_canStart || _camera != null) return;
    final revision = _requestRevision;
    final generation = ++_generation;
    FrameWorker? worker;
    try {
      if (_platform != TargetPlatform.android &&
          _platform != TargetPlatform.iOS) {
        throw UnsupportedError('Only Android and iOS are supported.');
      }
      final cameras = await availableCameras();
      if (!_isCurrent(generation)) return;
      if (cameras.isEmpty) throw StateError('No camera is available.');
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == _facing,
        orElse: () => cameras.first,
      );
      worker = await _startWorker();
      if (!_isCurrent(generation)) return;
      final camera = await _openCamera(description, generation, worker);
      if (camera == null) return;
      _worker = worker;
      worker = null;
      _camera = camera;
      _controller._update(running: true);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      if (!_isCurrent(generation)) return;
      if (revision == _requestRevision) _requested = false;
      rethrow;
    } finally {
      await worker?.close();
    }
  }

  Future<CameraController?> _openCamera(
    CameraDescription description,
    int generation,
    FrameWorker worker,
  ) async {
    final camera = CameraController(
      description,
      _controller.resolution,
      enableAudio: false,
      imageFormatGroup: _platform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    try {
      await camera.initialize();
      if (_isCurrent(generation)) {
        await camera.startImageStream(
          (image) => _onFrame(image, generation, worker),
        );
        if (_isCurrent(generation)) return camera;
      }
    } catch (_) {
      try {
        await _releaseCamera(camera);
      } catch (_) {
        // Preserve the initialization or stream error that caused cleanup.
      }
      rethrow;
    }
    await _releaseCamera(camera);
    return null;
  }

  Future<void> _onFrame(
    CameraImage image,
    int generation,
    FrameWorker worker,
  ) async {
    if (_decoding || !_isCurrent(generation) || _camera == null) return;
    _decoding = true;
    final frameRegion = widget.frameRegion;
    String? result;
    try {
      result = await worker.decode(image, frameRegion: frameRegion);
    } catch (error) {
      if (_isCurrent(generation) && frameRegion == widget.frameRegion) {
        final now = DateTime.now();
        final lastError = _lastFrameError;
        if (lastError == null ||
            now.difference(lastError) >= _frameErrorInterval) {
          _lastFrameError = now;
          _reportError(error);
        }
      }
    } finally {
      _decoding = false;
    }
    if (!_isCurrent(generation) ||
        frameRegion != widget.frameRegion ||
        result == null) {
      return;
    }
    final now = DateTime.now();
    final lastDetection = _lastDetection;
    if (_lastValue == result &&
        lastDetection != null &&
        now.difference(lastDetection) < _controller.duplicateFilterDuration) {
      return;
    }
    _lastValue = result;
    _lastDetection = now;
    if (!_controller._disposed) _controller._detections.add(result);
    widget.onDetected?.call(result);
  }

  void _resetFrameHistory() {
    _lastValue = null;
    _lastDetection = null;
    _lastFrameError = null;
  }

  Future<void> _releaseCamera(CameraController camera) async {
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    } finally {
      await camera.dispose();
    }
  }

  Future<void> _stop() async {
    ++_generation;
    _resetFrameHistory();
    final camera = _camera;
    final worker = _worker;
    _camera = null;
    _worker = null;
    if (_controller._state == this || _controller._state == null) {
      _controller._update(running: false, torch: false, zoom: 1);
    }
    if (mounted && !_closed) setState(() {});
    try {
      if (camera != null) await _releaseCamera(camera);
    } finally {
      await worker?.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_active) return;
        _active = true;
        if (_requested) _runAutomatically(_start);
      case AppLifecycleState.inactive:
        // Permission dialogs can make the app inactive during camera startup.
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (!_active) return;
        _active = false;
        ++_generation;
        _runAutomatically(_stop);
    }
  }

  @override
  void dispose() {
    _closed = true;
    ++_generation;
    _resetFrameHistory();
    WidgetsBinding.instance.removeObserver(this);
    _runAutomatically(_stop);
    _controller._state = null;
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    if (camera == null) {
      if (_switching) {
        return const ColoredBox(color: Colors.black, child: Center());
      }
      final error = _controller.error;
      if (error != null) {
        final builder = widget.errorBuilder;
        if (builder != null) return builder(context, error);
        final colors = Theme.of(context).colorScheme;
        return ColoredBox(
          color: colors.surface,
          child: Center(
            child: Text(
              'Camera unavailable',
              style: TextStyle(color: colors.onSurface),
            ),
          ),
        );
      }
      if (!_requested) return const SizedBox.shrink();
      return _buildLoading(context);
    }
    return ValueListenableBuilder<CameraValue>(
      valueListenable: camera,
      builder: (context, value, _) {
        final previewSize = value.previewSize;
        if (!value.isInitialized || previewSize == null) {
          return _buildLoading(context);
        }
        // CameraPreview rotates the texture on Android using this orientation.
        final orientation =
            value.previewPauseOrientation ??
            value.lockedCaptureOrientation ??
            value.deviceOrientation;
        final landscape =
            orientation == DeviceOrientation.landscapeLeft ||
            orientation == DeviceOrientation.landscapeRight;
        final size = landscape ? previewSize : previewSize.flipped;
        final nativeRatio = value.aspectRatio;
        final ratio = landscape ? nativeRatio : 1 / nativeRatio;
        if (!size.isFinite || size.isEmpty || !ratio.isFinite || ratio <= 0) {
          return _buildLoading(context);
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
              return SizedBox.fromSize(
                size: size,
                child: CameraPreview(camera, child: widget.overlay),
              );
            }
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: widget.fit,
                    child: SizedBox.fromSize(
                      size: size,
                      child: CameraPreview(camera),
                    ),
                  ),
                  if (widget.overlay != null) widget.overlay!,
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLoading(BuildContext context) =>
      widget.loadingBuilder?.call(context) ??
      const Center(child: CircularProgressIndicator());
}
