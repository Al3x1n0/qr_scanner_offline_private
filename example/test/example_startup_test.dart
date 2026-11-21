import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_scanner_example/main.dart';

void main() {
  testWidgets('example opens without widget lifecycle errors', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ScannerExample()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('example accepts a zero-width initial layout', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(width: 0, height: 600, child: ScannerExample()),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
