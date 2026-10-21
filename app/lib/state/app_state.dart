import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twm_model/twm_model.dart';

/// Global state of the application (the TWM main panel and its local
/// variables). UI widgets listen to it via [AppScope].
class AppState extends ChangeNotifier {
  final TwmBackend backend;
  AppSettings settings;

  AppState(this.backend, this.settings) {
    _sub = backend.events.listen(_onEvent);
  }

  late final StreamSubscription<BackendEvent> _sub;
  Timer? _saveTimer;

  // ----------------------------------------------------- measurement state
  bool measuring = false;
  String status = 'READY';
  double progress = 0;
  int record = 0;
  int records = 0;
  String currentSession = '';
  WaveformEvent? lastWaveform;
  OnlineResult? lastOnline;

  // ------------------------------------------------------ processing state
  bool processing = false;
  int resultsVersion = 0; // incremented on every new result
  final List<String> errors = [];

  /// Error of the last measurement or processing (shown in the status until
  /// the next start, so a failed run is not mistaken for a finished one).
  String lastRunError = '';
  final List<ConsoleEvent> console = [];
  String rawOutput = '';

  /// Session shown in the results viewer: '' = current measurement.
  String viewedSession = '';
  bool viewerEnabled = true;

  /// Last known hardware identifiers (from TEST).
  List<String> channelIdns = [];

  String get resultsSession => viewedSession.isNotEmpty ? viewedSession : currentSession;

  static Future<AppState> create(TwmBackend backend) async {
    final s = await backend.loadSettings();
    final st = AppState(backend, s);
    if (s.lastSession.isNotEmpty && await backend.exists(s.lastSession)) {
      st.currentSession = s.lastSession;
    }
    return st;
  }

  void _onEvent(BackendEvent e) {
    switch (e) {
      case StatusEvent():
        status = e.message;
        progress = e.progress;
        record = e.record;
        records = e.records;
      case WaveformEvent():
        lastWaveform = e;
        if (e.online != null) lastOnline = OnlineResult.fromJson(e.online!);
      case RecordStoredEvent():
        currentSession = e.sessionPath;
        settings.lastSession = e.sessionPath;
        viewedSession = '';
      case FinishedEvent():
        measuring = false;
        if (e.error.isNotEmpty) {
          lastRunError = e.error;
          addError(e.error);
        }
        if (e.sessionPath.isNotEmpty) {
          currentSession = e.sessionPath;
          // auto increment of %id% in measurement name
          if (settings.measurement.nameBase.contains('%id%') && !e.aborted) {
            settings.measurement.measurementId++;
          }
        }
        saveSettings();
      case ConsoleEvent():
        console.add(e);
        if (console.length > 2000) console.removeRange(0, console.length - 2000);
        if (!e.isCommand && !e.isError && settings.measurement.processing.mode == ProcessingMode.raw) {
          rawOutput = e.text;
        }
      case ProcessingEvent():
        processing = e.busy;
        if (e.error.isNotEmpty) {
          lastRunError = e.error;
          addError('Processing record ${e.record}: ${e.error}');
        }
        if (!e.busy && e.error.isEmpty) resultsVersion++;
    }
    notifyListeners();
  }

  void addError(String e) {
    errors.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $e');
    notifyListeners();
  }

  void clearErrors() {
    errors.clear();
    notifyListeners();
  }

  void clearConsole() {
    console.clear();
    notifyListeners();
  }

  /// Persist settings (debounced).
  void saveSettings() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => backend.saveSettings(settings));
  }

  void update(void Function(AppSettings s) f) {
    f(settings);
    saveSettings();
    notifyListeners();
  }

  void touch() => notifyListeners();

  Future<String> startMeasurement() async {
    measuring = true;
    lastRunError = '';
    status = 'Starting...';
    lastWaveform = null;
    notifyListeners();
    try {
      final p = await backend.startMeasurement(settings);
      return p;
    } catch (e) {
      measuring = false;
      addError('$e');
      rethrow;
    }
  }

  Future<void> stop() async {
    status = 'Stopping...';
    notifyListeners();
    await backend.stopMeasurement();
    if (processing) await backend.stopProcessing();
  }

  @override
  void dispose() {
    _sub.cancel();
    _saveTimer?.cancel();
    backend.saveSettings(settings);
    super.dispose();
  }
}

/// Provides [AppState] to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Access without subscribing to changes.
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/// [showDialog] with [AppScope] above the dialog content. The state is taken
/// from [context] right away: the caller (a menu item that is rebuilt in a
/// different layout, a list row) may be unmounted when the dialog rebuilds.
Future<T?> showScopedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final state = AppScope.read(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (c) => AppScope(state: state, child: builder(c)),
  );
}
