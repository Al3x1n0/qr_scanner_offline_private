import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart' show CameraImage;
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_scanner_offline_private/qr_scanner_offline_private.dart';
import 'package:qr_scanner_offline_private/src/frame_worker.dart';
import 'package:qr_scanner_offline_private/src/scanner_view.dart'
    show OfflineQrScannerState;

void main() {
  testWidgets('manual start reports unsupported platform errors', (
    tester,
  ) async {
    final controller = OfflineQrScannerController(autoStart: false);
    Object? reportedError;
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineQrScanner(
          controller: controller,
          onDetected: (_) {},
          onError: (error) => reportedError = error,
        ),
      ),
    );
    expect(controller.isRunning, isFalse);
    final start = controller.start();
    await expectLater(start, throwsUnsupportedError);
    expect(reportedError, isA<UnsupportedError>());
    await tester.pumpWidget(const SizedBox());
    expect(() => controller.start(), throwsStateError);
    controller.dispose();
  });

  testWidgets('automatic start failure stops retries and shows an error', (
    tester,
  ) async {
    final controller = OfflineQrScannerController();
    var errors = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineQrScanner(
          controller: controller,
          onError: (_) => errors++,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(errors, 1);
    expect(controller.error, isA<UnsupportedError>());
    expect(find.text('Camera unavailable'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(errors, 1);
    await expectLater(controller.start(), throwsUnsupportedError);
    await tester.pump();
    expect(errors, 2);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('rejects negative duplicate intervals', () {
    final controller = OfflineQrScannerController();
    expect(
      () => controller.duplicateFilterDuration = const Duration(seconds: -1),
      throwsArgumentError,
    );
    controller.dispose();
  });

  group('camera sessions', () {
    late _CameraPlatform platform;
    late OfflineQrScannerController controller;
    late List<_FrameWorker> workers;

    setUp(() {
      final previous = CameraPlatform.instance;
      platform = _CameraPlatform();
      CameraPlatform.instance = platform;
      addTearDown(() => CameraPlatform.instance = previous);
      controller = OfflineQrScannerController(autoStart: false);
      workers = [];
      addTearDown(() => controller.dispose());
    });

    Future<void> mount(
      WidgetTester tester, {
      ValueChanged<String>? onDetected,
      ValueChanged<Object>? onError,
      Widget Function(BuildContext, Object)? errorBuilder,
      WidgetBuilder? loadingBuilder,
      Rect? frameRegion,
    }) => tester.pumpWidget(
      MaterialApp(
        home: _TestScanner(
          controller: controller,
          onDetected: onDetected,
          onError: onError,
          errorBuilder: errorBuilder,
          loadingBuilder: loadingBuilder,
          frameRegion: frameRegion,
          startWorker: () async {
            final worker = _FrameWorker();
            workers.add(worker);
            return worker;
          },
        ),
      ),
    );

    testWidgets('pauses only on backgrounding and resumes requested scanning', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await mount(tester);
      await controller.start();
      expect(platform.enumerations, 0);

      final starting = platform.beforeInitialize = Completer<void>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(platform.enumerations, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      starting.complete();
      await tester.pump();
      expect(controller.isRunning, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(platform.enumerations, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(controller.isRunning, isTrue);
      expect(platform.teardown, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.isRunning, isFalse);
      expect(platform.teardown, ['stop:1', 'dispose:1']);
      expect(workers.single.closed, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(controller.isRunning, isTrue);
      expect(platform.enumerations, 2);
      await tester.pumpWidget(const SizedBox());
      expect(platform.teardown, ['stop:1', 'dispose:1', 'stop:2', 'dispose:2']);
      expect(workers.last.closed, isTrue);
    });

    testWidgets('clears errors in the order of queued start requests', (
      tester,
    ) async {
      final gate = platform.beforeInitialize = Completer<void>();
      final error = CameraException('denied', 'Camera permission denied.');
      final seen = <Object?>[];
      controller.addListener(() => seen.add(controller.error));
      await mount(
        tester,
        errorBuilder: (_, _) => const Text('Custom unavailable'),
        loadingBuilder: (_) => const Text('Custom loading'),
      );
      final start = controller.start();
      final failure = expectLater(start, throwsA(same(error)));
      await tester.pump();
      expect(find.text('Custom loading'), findsOneWidget);

      final retry = controller.start();
      gate.completeError(error);
      await failure;
      await retry;
      expect(seen, [error, null, null]);
      expect(controller.error, isNull);
      expect(controller.isRunning, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'ignores a failed initialization superseded by stop and start',
      (tester) async {
        final gate = platform.beforeInitialize = Completer<void>();
        final errors = <Object>[];
        await mount(tester, onError: errors.add);
        final start = controller.start();
        await tester.pump();

        final stop = controller.stop();
        final restart = controller.start();
        gate.completeError(
          CameraException('interrupted', 'Camera interrupted.'),
        );
        await start;
        await stop;
        await restart;
        expect(errors, isEmpty);
        expect(controller.error, isNull);
        expect(controller.isRunning, isTrue);
        expect(workers.first.closed, isTrue);
        expect(platform.teardown, ['dispose:1']);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('shows custom placeholders with invalid preview dimensions', (
      tester,
    ) async {
      platform.previewSize = const Size(640, 0);
      await mount(
        tester,
        errorBuilder: (_, _) => const Text('Custom unavailable'),
        loadingBuilder: (_) => const Text('Custom loading'),
      );
      await controller.start();
      await tester.pump();
      expect(find.text('Custom loading'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await controller.stop();
      await expectLater(controller.switchCamera(), throwsStateError);
      await tester.pump();
      expect(find.text('Custom unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('switches active camera with one lookup and no loading state', (
      tester,
    ) async {
      await mount(tester, loadingBuilder: (_) => const Text('Custom loading'));
      await expectLater(controller.switchCamera(), throwsStateError);
      expect(platform.enumerations, 0);
      await controller.start();
      expect(platform.opened, [CameraLensDirection.back]);
      expect(platform.audioSettings, [false]);
      await controller.setTorch(true);
      await controller.setZoomScale(2);
      expect(platform.flashMode, FlashMode.torch);
      expect(platform.zoom, 2);
      expect(await controller.getZoomRange(), (min: 1.0, max: 4.0));
      await expectLater(
        controller.setZoomScale(double.nan),
        throwsArgumentError,
      );
      expect(controller.zoomScale, 2);

      final gate = platform.beforeInitialize = Completer<void>();
      final switching = controller.switchCamera();
      await tester.pump();
      expect(find.text('Custom loading'), findsNothing);
      expect(controller.isRunning, isTrue);
      gate.complete();
      await switching;
      expect(platform.enumerations, 2);
      expect(platform.opened, [
        CameraLensDirection.back,
        CameraLensDirection.front,
      ]);
      expect(platform.teardown, ['stop:1', 'dispose:1']);
      expect(controller.torchEnabled, isFalse);
      expect(controller.zoomScale, 1);
      expect(workers, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keeps the previous camera preference after switch failure', (
      tester,
    ) async {
      await mount(tester);
      await controller.start();
      final gate = platform.beforeInitialize = Completer<void>();
      final switching = controller.switchCamera();
      final failure = expectLater(switching, throwsA(isA<CameraException>()));
      await tester.pump();
      gate.completeError(
        CameraException('unavailable', 'Camera disconnected.'),
      );
      await failure;
      expect(controller.isRunning, isFalse);
      expect(workers.single.closed, isTrue);
      await controller.start();
      expect(platform.opened, [
        CameraLensDirection.back,
        CameraLensDirection.front,
        CameraLensDirection.back,
      ]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('filters duplicate results and throttles frame errors', (
      tester,
    ) async {
      controller.duplicateFilterDuration = const Duration(minutes: 1);
      const region = Rect.fromLTRB(.1, .2, .8, .9);
      final detected = <String>[];
      final streamed = <String>[];
      final errors = <Object>[];
      final subscription = controller.detections.listen(streamed.add);
      addTearDown(subscription.cancel);
      await mount(
        tester,
        onDetected: detected.add,
        onError: errors.add,
        frameRegion: region,
      );
      await controller.start();
      final worker = workers.single;
      for (var index = 0; index < 3; index++) {
        platform.emit();
        await tester.pump();
      }
      expect(worker.lastRegion, region);
      expect(detected, ['test QR']);
      expect(streamed, detected);
      worker.result = 'other test QR';
      platform.emit();
      await tester.pump();
      expect(detected, ['test QR', 'other test QR']);

      worker.error = const FormatException('Test decode error.');
      platform.emit();
      await tester.pump();
      platform.emit();
      await tester.pump();
      expect(errors, [worker.error]);

      worker.error = null;
      worker.pending = Completer<String?>();
      platform.emit();
      await tester.pump();
      await controller.stop();
      worker.pending!.complete('stale test QR');
      await tester.pump();
      expect(detected, ['test QR', 'other test QR']);
      expect(streamed, detected);

      await controller.start();
      workers.last.result = 'other test QR';
      platform.emit();
      await tester.pump();
      expect(detected, ['test QR', 'other test QR', 'other test QR']);
      expect(streamed, detected);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _TestScanner extends OfflineQrScanner {
  const _TestScanner({
    super.controller,
    super.onDetected,
    super.onError,
    super.errorBuilder,
    super.loadingBuilder,
    super.frameRegion,
    required this.startWorker,
  });

  final Future<FrameWorker> Function() startWorker;

  @override
  State<OfflineQrScanner> createState() =>
      // The fake worker is fixed when the test widget is created.
      // ignore: no_logic_in_create_state
      OfflineQrScannerState.testing(TargetPlatform.android, startWorker);
}

class _FrameWorker implements FrameWorker {
  String result = 'test QR';
  Object? error;
  Rect? lastRegion;
  Completer<String?>? pending;
  bool closed = false;

  @override
  Future<String?> decode(CameraImage image, {Rect? frameRegion}) async {
    lastRegion = frameRegion;
    final failure = error;
    if (failure != null) throw failure;
    final inFlight = pending;
    if (inFlight != null) return inFlight.future;
    return result;
  }

  @override
  Future<void> close() async => closed = true;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CameraPlatform extends CameraPlatform {
  static const _back = CameraDescription(
    name: 'back',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );
  static const _front = CameraDescription(
    name: 'front',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 270,
  );
  final opened = <CameraLensDirection>[];
  final audioSettings = <bool>[];
  final teardown = <String>[];
  final _streams = <int, StreamController<CameraImageData>>{};
  Size previewSize = const Size(640, 480);
  int enumerations = 0;
  int _id = 0;
  FlashMode? flashMode;
  double? zoom;
  Completer<void>? beforeInitialize;

  @override
  Future<List<CameraDescription>> availableCameras() async {
    enumerations++;
    return [_back, _front];
  }

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    audioSettings.add(mediaSettings.enableAudio);
    opened.add(cameraDescription.lensDirection);
    return ++_id;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    final gate = beforeInitialize;
    beforeInitialize = null;
    await gate?.future;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          previewSize.width,
          previewSize.height,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => Stream.multi((_) {});

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    final stream = StreamController<CameraImageData>(
      onCancel: () async {
        teardown.add('stop:$cameraId');
      },
    );
    _streams[cameraId] = stream;
    return stream.stream;
  }

  void emit() {
    _streams[_id]!.add(
      CameraImageData(
        format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
        planes: [
          CameraImagePlane(
            bytes: Uint8List(4),
            bytesPerRow: 2,
            bytesPerPixel: 1,
          ),
        ],
        height: 2,
        width: 2,
      ),
    );
  }

  @override
  Widget buildPreview(int cameraId) => const SizedBox();

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {
    flashMode = mode;
  }

  @override
  Future<double> getMinZoomLevel(int cameraId) async => 1;

  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 4;

  @override
  Future<void> setZoomLevel(int cameraId, double value) async => zoom = value;

  @override
  Future<void> dispose(int cameraId) async {
    teardown.add('dispose:$cameraId');
    unawaited(_streams.remove(cameraId)?.close());
  }
}
