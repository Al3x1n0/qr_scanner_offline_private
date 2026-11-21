import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:qr_scanner_offline_private/qr_scanner_offline_private.dart';

void main() => runApp(const MaterialApp(home: ScannerExample()));

class ScannerExample extends StatefulWidget {
  const ScannerExample({super.key});

  @override
  State<ScannerExample> createState() => _ScannerExampleState();
}

class _ScannerExampleState extends State<ScannerExample> {
  static final _displayControls = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
  );

  final _controller = OfflineQrScannerController(
    duplicateFilterDuration: const Duration(milliseconds: 750),
  );
  String? _lastValue;
  String? _error;
  bool _square = false;
  bool _cover = true;
  bool _overlay = false;
  int _eventCount = 0;
  late StreamSubscription<String> _subscription;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refresh);
    _subscription = _controller.detections.listen((_) {
      if (mounted) setState(() => _eventCount++);
    });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _showError() {
    if (mounted) {
      setState(() => _error = 'Operazione dello scanner non riuscita.');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _showError();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _subscription.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scanner = OfflineQrScanner(
      controller: _controller,
      fit: _cover ? BoxFit.cover : BoxFit.contain,
      overlay: _overlay
          ? IgnorePointer(
              child: Center(
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.greenAccent, width: 3),
                  ),
                ),
              ),
            )
          : null,
      onDetected: (value) {
        final displayValue = value.replaceAllMapped(
          _displayControls,
          (match) => '\\u{${match.group(0)!.codeUnitAt(0).toRadixString(16)}}',
        );
        if (_lastValue != displayValue || _error != null) {
          setState(() {
            _lastValue = displayValue;
            _error = null;
          });
        }
      },
      onError: (_) => _showError(),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Test scanner QR')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = (constraints.maxWidth - 32).clamp(
              0.0,
              double.infinity,
            );
            final side = availableWidth.clamp(0.0, 300.0);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: SizedBox(
                      width: _square ? side : availableWidth,
                      height: _square ? side : 250,
                      child: ColoredBox(color: Colors.black, child: scanner),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _controller.isRunning
                        ? 'Fotocamera attiva'
                        : 'Fotocamera ferma',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => _run(_controller.start),
                        child: const Text('Avvia'),
                      ),
                      OutlinedButton(
                        onPressed: () => _run(_controller.stop),
                        child: const Text('Ferma'),
                      ),
                      OutlinedButton(
                        onPressed: _controller.isRunning
                            ? () => _run(_controller.toggleTorch)
                            : null,
                        child: Text(
                          _controller.torchEnabled
                              ? 'Spegni torcia'
                              : 'Accendi torcia',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => _run(_controller.switchCamera),
                        child: const Text('Cambia fotocamera'),
                      ),
                      OutlinedButton(
                        onPressed: !_controller.isRunning
                            ? null
                            : () => _run(() async {
                                final range = await _controller.getZoomRange();
                                await _controller.setZoomScale(range.min);
                              }),
                        child: const Text('Zoom minimo'),
                      ),
                      OutlinedButton(
                        onPressed: !_controller.isRunning
                            ? null
                            : () => _run(() async {
                                final range = await _controller.getZoomRange();
                                final zoom = (_controller.zoomScale + 0.5)
                                    .clamp(range.min, range.max);
                                await _controller.setZoomScale(zoom);
                              }),
                        child: const Text('Aumenta zoom'),
                      ),
                      OutlinedButton(
                        onPressed: () => setState(() => _square = !_square),
                        child: Text(
                          _square ? 'Anteprima larga' : 'Anteprima quadrata',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => setState(() => _cover = !_cover),
                        child: Text(
                          _cover
                              ? 'Mostra intera anteprima'
                              : 'Riempi anteprima',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => setState(() => _overlay = !_overlay),
                        child: Text(
                          _overlay ? 'Nascondi cornice' : 'Mostra cornice',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () {
                          _controller.duplicateFilterDuration =
                              _controller.duplicateFilterDuration ==
                                  Duration.zero
                              ? const Duration(milliseconds: 750)
                              : Duration.zero;
                        },
                        child: Text(
                          _controller.duplicateFilterDuration == Duration.zero
                              ? 'Attiva filtro duplicati'
                              : 'Disattiva filtro duplicati',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Ultimo QR letto',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text('Eventi ricevuti dallo stream: $_eventCount'),
                  const SizedBox(height: 6),
                  SelectableText(_lastValue ?? 'Inquadra un QR code'),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() {
                        _lastValue = null;
                        _error = null;
                        _eventCount = 0;
                      }),
                      child: const Text('Cancella risultato'),
                    ),
                  ),
                  const Text(
                    'Il ritaglio modifica solo l’anteprima; il decoder analizza tutto il fotogramma.',
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
