/// Events pushed from backend to the UI (serializable for WebSocket).
library;

import '../json.dart';

sealed class BackendEvent {
  const BackendEvent();

  String get type;
  Json toJson();

  static BackendEvent fromJson(Json j) => switch (jString(j['type'])) {
    'status' => StatusEvent.fromJson(j),
    'waveform' => WaveformEvent.fromJson(j),
    'record' => RecordStoredEvent.fromJson(j),
    'finished' => FinishedEvent.fromJson(j),
    'console' => ConsoleEvent.fromJson(j),
    'processing' => ProcessingEvent.fromJson(j),
    'live' => LiveEvent.fromJson(j),
    _ => StatusEvent('unknown event ${j['type']}'),
  };
}

/// Measurement status line / progress.
class StatusEvent extends BackendEvent {
  final String message;
  final double progress;
  final int record;
  final int records;
  const StatusEvent(this.message, {this.progress = 0, this.record = 0, this.records = 0});
  @override
  String get type => 'status';
  @override
  Json toJson() => {'type': type, 'message': message, 'progress': progress, 'record': record, 'records': records};
  factory StatusEvent.fromJson(Json j) => StatusEvent(
    jString(j['message']),
    progress: jDouble(j['progress']),
    record: jInt(j['record']),
    records: jInt(j['records']),
  );
}

/// Last acquired waveform (decimated) and its spectrum for live views.
class WaveformEvent extends BackendEvent {
  final int record;
  final List<String> names;
  final List<List<double>> channels;
  final double ts;

  /// Amplitude spectra (one per channel), frequency step [df].
  final List<List<double>> spectra;
  final double df;

  /// On-line analysis results (TPQA "CVI data processing").
  final Json? online;

  const WaveformEvent(
    this.record,
    this.names,
    this.channels,
    this.ts, {
    this.spectra = const [],
    this.df = 0,
    this.online,
  });
  @override
  String get type => 'waveform';
  @override
  Json toJson() => {
    'type': type,
    'record': record,
    'names': names,
    'channels': channels,
    'ts': ts,
    'spectra': spectra,
    'df': df,
    'online': online,
  };
  factory WaveformEvent.fromJson(Json j) => WaveformEvent(
    jInt(j['record']),
    jStringList(j['names']),
    [for (final c in (j['channels'] as List? ?? [])) jDoubleList(c)],
    jDouble(j['ts']),
    spectra: [for (final c in (j['spectra'] as List? ?? [])) jDoubleList(c)],
    df: jDouble(j['df']),
    online: j['online'] == null ? null : jMap(j['online']),
  );
}

/// Oscilloscope-like live view: the newest samples of the record being
/// acquired, starting at a rising crossing of the first channel (software
/// trigger), up to ~30 frames per second.
class LiveEvent extends BackendEvent {
  final int record;
  final List<String> names;
  final List<List<double>> channels;

  /// Time step of [channels], time of their first point after the trigger
  /// crossing, window length [s].
  final double dx;
  final double x0;
  final double span;
  final bool triggered;

  const LiveEvent(
    this.record,
    this.names,
    this.channels,
    this.dx, {
    this.x0 = 0,
    this.span = 0,
    this.triggered = false,
  });
  @override
  String get type => 'live';
  @override
  Json toJson() => {
    'type': type,
    'record': record,
    'names': names,
    'channels': [for (final c in channels) [for (final v in c) jNum(v)]],
    'dx': dx,
    'x0': x0,
    'span': span,
    'triggered': triggered,
  };
  factory LiveEvent.fromJson(Json j) => LiveEvent(
    jInt(j['record']),
    jStringList(j['names']),
    [for (final c in (j['channels'] as List? ?? [])) jDoubleList(c)],
    jDouble(j['dx']),
    x0: jDouble(j['x0']),
    span: jDouble(j['span']),
    triggered: jBool(j['triggered']),
  );
}

class RecordStoredEvent extends BackendEvent {
  final String sessionPath;
  final int group;
  final int record;
  const RecordStoredEvent(this.sessionPath, this.group, this.record);
  @override
  String get type => 'record';
  @override
  Json toJson() => {'type': type, 'sessionPath': sessionPath, 'group': group, 'record': record};
  factory RecordStoredEvent.fromJson(Json j) =>
      RecordStoredEvent(jString(j['sessionPath']), jInt(j['group']), jInt(j['record']));
}

class FinishedEvent extends BackendEvent {
  final String sessionPath;
  final bool aborted;
  final String error;
  const FinishedEvent(this.sessionPath, {this.aborted = false, this.error = ''});
  @override
  String get type => 'finished';
  @override
  Json toJson() => {'type': type, 'sessionPath': sessionPath, 'aborted': aborted, 'error': error};
  factory FinishedEvent.fromJson(Json j) =>
      FinishedEvent(jString(j['sessionPath']), aborted: jBool(j['aborted']), error: jString(j['error']));
}

class ConsoleEvent extends BackendEvent {
  final String text;
  final bool isError;
  final bool isCommand;
  const ConsoleEvent(this.text, {this.isError = false, this.isCommand = false});
  @override
  String get type => 'console';
  @override
  Json toJson() => {'type': type, 'text': text, 'isError': isError, 'isCommand': isCommand};
  factory ConsoleEvent.fromJson(Json j) =>
      ConsoleEvent(jString(j['text']), isError: jBool(j['isError']), isCommand: jBool(j['isCommand']));
}

/// Processing state: a record was processed (new result available) or
/// processing failed.
class ProcessingEvent extends BackendEvent {
  final String sessionPath;
  final int record;
  final bool busy;
  final String error;
  const ProcessingEvent(this.sessionPath, {this.record = 0, this.busy = false, this.error = ''});
  @override
  String get type => 'processing';
  @override
  Json toJson() => {'type': type, 'sessionPath': sessionPath, 'record': record, 'busy': busy, 'error': error};
  factory ProcessingEvent.fromJson(Json j) => ProcessingEvent(
    jString(j['sessionPath']),
    record: jInt(j['record']),
    busy: jBool(j['busy']),
    error: jString(j['error']),
  );
}
