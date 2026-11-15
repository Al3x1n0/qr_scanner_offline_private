import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_scanner_offline_private/qr_scanner_offline_private.dart';

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
}
