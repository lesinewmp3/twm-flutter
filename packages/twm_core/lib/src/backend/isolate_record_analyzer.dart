import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:twm_engine/twm_engine.dart';
import 'package:twm_model/twm_model.dart';

/// Record analysis (spectra, on-line analysis) in a worker isolate: the
/// acquisition and the monitor keep running while a long record of a fast
/// digitizer is analysed (seconds at MSa/s).
class IsolateRecordAnalyzer implements RecordAnalyzer {
  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _recv;
  final _replies = <Completer<RecordAnalysis>>[];

  IsolateRecordAnalyzer._(this._isolate, this._send, this._recv) {
    _recv.listen((m) {
      if (m is RecordAnalysis && _replies.isNotEmpty) _replies.removeAt(0).complete(m);
    });
  }

  static Future<IsolateRecordAnalyzer> spawn(AppSettings settings) async {
    final recv = ReceivePort();
    final ready = Completer<SendPort>();
    final first = recv.first; // the worker's port
    final isolate = await Isolate.spawn(_worker, (recv.sendPort, settings.toJson()), debugName: 'record analysis');
    ready.complete(await first as SendPort);
    // the first message consumed the port: a new one for the replies
    final replies = ReceivePort();
    final send = await ready.future;
    send.send(replies.sendPort);
    return IsolateRecordAnalyzer._(isolate, send, replies);
  }

  static Future<void> _worker((SendPort, Json) args) async {
    final (out, settings) = args;
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    final analyzer = InlineRecordAnalyzer(AppSettings.fromJson(settings));
    SendPort? reply;
    await for (final m in inbox) {
      if (m is SendPort) {
        reply = m;
      } else if (m is (List<Float64List>, double)) {
        RecordAnalysis a;
        try {
          a = analyzer.run(m.$1, m.$2);
        } catch (e) {
          a = RecordAnalysis(error: '$e');
        }
        reply?.send(a);
      } else if (m == null) {
        inbox.close();
      }
    }
  }

  @override
  Future<RecordAnalysis> analyze(List<Float64List> channels, double fs) {
    final c = Completer<RecordAnalysis>();
    _replies.add(c);
    _send.send((channels, fs));
    return c.future;
  }

  @override
  Future<void> close() async {
    _send.send(null);
    _recv.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    for (final c in _replies) {
      c.complete(const RecordAnalysis(error: 'analysis stopped'));
    }
    _replies.clear();
  }
}
