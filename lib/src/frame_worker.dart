import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';

import 'decoder.dart';

/// Runs luma conversion and native decoding off the scanner's UI isolate.
class FrameWorker {
  FrameWorker._(this._events);

  final ReceivePort _events;
  final _ready = Completer<void>();
  final _exited = Completer<void>();
  late final SendPort _commands;
  Completer<String?>? _pending;
  bool _closing = false;

  static Future<FrameWorker> start() async {
    final events = ReceivePort();
    final worker = FrameWorker._(events);
    try {
      await Isolate.spawn(
        _runFrameWorker,
        events.sendPort,
        onExit: events.sendPort,
        onError: events.sendPort,
      );
    } catch (_) {
      events.close();
      rethrow;
    }
    events.listen(worker._receive);
    await worker._ready.future;
    return worker;
  }

  Future<String?> decode(CameraImage image, {Rect? frameRegion}) async {
    if (_closing || _exited.isCompleted || _pending != null) {
      throw StateError('The frame worker is unavailable.');
    }
    validateFrameRegion(frameRegion);
    final layout = LumaLayout.fromImage(image);
    // Transfer only the luma or BGRA plane. Creating the transfer buffer still
    // makes a copy of the camera plugin's bytes on the calling isolate.
    final bytes = Uint8List.sublistView(
      image.planes.first.bytes,
      0,
      layout.byteLength,
    );
    final request = _FrameRequest(
      layout,
      TransferableTypedData.fromList([bytes]),
      frameRegion,
    );
    final reply = Completer<String?>();
    _pending = reply;
    try {
      _commands.send(request);
      return await reply.future;
    } finally {
      _pending = null;
    }
  }

  Future<void> close() async {
    if (!_closing && !_exited.isCompleted) {
      _closing = true;
      _commands.send(null);
    }
    await _exited.future;
  }

  void _receive(Object? event) {
    if (event is SendPort) {
      _commands = event;
      _ready.complete();
    } else if (event is _FrameReply) {
      final request = _pending!;
      final error = event.error;
      if (error == null) {
        request.complete(event.text);
      } else {
        request.completeError(error);
      }
    } else if (event == null) {
      // An isolate error is followed by an exit message. Keep its raw details
      // inside the worker and resolve outstanding work with a safe error.
      final error = StateError('The frame worker stopped.');
      if (!_ready.isCompleted) _ready.completeError(error);
      final request = _pending;
      if (request != null && !request.isCompleted) request.completeError(error);
      _exited.complete();
      _events.close();
    }
  }
}

class _FrameRequest {
  const _FrameRequest(this.layout, this.bytes, this.region);

  final LumaLayout layout;
  final TransferableTypedData bytes;
  final Rect? region;
}

class _FrameReply {
  const _FrameReply({this.text, this.error});

  final String? text;
  final Object? error;
}

Future<void> _runFrameWorker(SendPort replies) async {
  final requests = ReceivePort();
  final decoder = FrameDecoder();
  replies.send(requests.sendPort);
  var useAdaptiveThreshold = true;
  try {
    await for (final Object? message in requests) {
      if (message == null) break;
      final request = message as _FrameRequest;
      final raw = request.bytes.materialize().asUint8List();
      Frame? frame;
      _FrameReply reply;
      try {
        frame = request.layout.extract(raw, region: request.region);
        final text = frame == null
            ? null
            : decoder.decode(frame, useAdaptiveThreshold: useAdaptiveThreshold);
        useAdaptiveThreshold = !useAdaptiveThreshold;
        reply = _FrameReply(text: text);
      } on FormatException catch (error) {
        reply = _FrameReply(error: error);
      } on StateError catch (error) {
        reply = _FrameReply(error: error);
      } on UnsupportedError catch (error) {
        reply = _FrameReply(error: error);
      } catch (_) {
        reply = _FrameReply(
          error: StateError('Unable to decode the camera frame.'),
        );
      } finally {
        raw.fillRange(0, raw.length, 0);
        if (frame != null) frame.pixels.fillRange(0, frame.pixels.length, 0);
      }
      replies.send(reply);
    }
  } finally {
    requests.close();
    decoder.dispose();
  }
}
