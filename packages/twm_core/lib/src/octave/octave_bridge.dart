import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:twm_model/twm_model.dart';

/// Error raised in GNU Octave/Matlab while executing a command.
class OctaveException implements Exception {
  final String message;
  OctaveException(this.message);
  @override
  String toString() => message;
}

/// Line of the calculation engine console (for the console view).
class ConsoleLine {
  final String text;
  final bool isError;
  final bool isCommand;
  const ConsoleLine(this.text, {this.isError = false, this.isCommand = false});
}

/// Bridge to a persistent GNU Octave (or Matlab) process - replacement of
/// the GOLPI interface used by the LabVIEW TWM.
///
/// Commands are serialized (only one at a time, like the TWM multi-process
/// GOLPI semaphore). Each command is wrapped in try/catch and terminated by
/// a unique marker printed to stdout, so the output and errors of every
/// command are captured reliably.
class OctaveBridge {
  OctaveConfig config;

  /// Folder with the m-files of this port (`octave/api`, `octave/compat`).
  final String apiRoot;

  OctaveBridge(this.config, {required this.apiRoot});

  Process? _proc;
  final _console = StreamController<ConsoleLine>.broadcast();
  final _lines = StreamController<String>.broadcast();
  Future<void> _queue = Future.value();
  int _cmdId = 0;
  Map<String, dynamic>? _initInfo;

  static const _done = '@@TWMDONE@@';
  static const _err = '@@TWMERR@@';
  static const _json = '@@TWMJSON@@';

  Stream<ConsoleLine> get console => _console.stream;
  bool get isRunning => _proc != null;
  Map<String, dynamic>? get initInfo => _initInfo;

  String get octprogPath => config.octprogPath;
  String get qwtbPath => config.qwtbPath.isNotEmpty ? config.qwtbPath : p.join(config.octprogPath, 'qwtb');

  /// Resolves the Octave/Matlab executable from the configuration.
  String resolveExecutable() {
    if (config.engine == CalcEngine.matlab) {
      final m = config.matlabPath;
      if (m.isEmpty) return 'matlab';
      return FileSystemEntity.isDirectorySync(m) ? p.join(m, Platform.isWindows ? 'matlab.exe' : 'matlab') : m;
    }
    final o = config.octavePath;
    final exe = Platform.isWindows ? 'octave-cli.exe' : 'octave-cli';
    if (o.isEmpty) return Platform.isWindows ? (_findWindowsOctave(exe) ?? exe) : exe;
    if (FileSystemEntity.isDirectorySync(o)) {
      for (final sub in ['', 'bin', p.join('mingw64', 'bin'), p.join('mingw32', 'bin')]) {
        final f = p.join(o, sub, exe);
        if (File(f).existsSync()) return f;
      }
      return p.join(o, exe);
    }
    return o;
  }

  /// The Windows installer of GNU Octave does not add it to PATH: picks the
  /// newest `<Program Files>\GNU Octave\Octave-*\mingw64\bin\octave-cli.exe`.
  static String? _findWindowsOctave(String exe) {
    final roots = {
      Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
      Platform.environment['LOCALAPPDATA'] == null ? null : p.join(Platform.environment['LOCALAPPDATA']!, 'Programs'),
    }.whereType<String>();
    final found = <String>[];
    for (final r in roots) {
      final d = Directory(p.join(r, 'GNU Octave'));
      if (!d.existsSync()) continue;
      for (final v in d.listSync().whereType<Directory>()) {
        final f = p.join(v.path, 'mingw64', 'bin', exe);
        if (File(f).existsSync()) found.add(f);
      }
    }
    if (found.isEmpty) return null;
    // "Octave-10.1.0" must win over "Octave-9.2.0"
    List<int> ver(String f) =>
        RegExp(r'\d+').allMatches(p.basename(p.dirname(p.dirname(p.dirname(f))))).map((m) => int.parse(m[0]!)).toList();
    int cmp(List<int> a, List<int> b) {
      for (var i = 0; i < a.length && i < b.length; i++) {
        if (a[i] != b[i]) return a[i] - b[i];
      }
      return a.length - b.length;
    }
    found.sort((a, b) => cmp(ver(a), ver(b)));
    return found.last;
  }

  /// Starts the engine (if not running) and initializes paths/packages.
  Future<Map<String, dynamic>> start() async {
    if (_proc != null) return _initInfo ?? {};
    final exe = resolveExecutable();
    final args = config.engine == CalcEngine.matlab
        ? ['-nodesktop', '-nosplash', '-nodisplay']
        : ['--quiet', '--no-gui', '--no-history', '--no-line-editing'];
    _log('> start $exe ${args.join(' ')}', command: true);
    final Process proc;
    try {
      proc = await Process.start(exe, args, runInShell: Platform.isWindows);
    } on ProcessException catch (e) {
      throw OctaveException(
        'Cannot start "$exe": ${e.message}. '
        'Check the GNU Octave/Matlab path in the configuration.',
      );
    }
    _proc = proc;
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      _lines.add(l);
      if (!l.startsWith(_done) && !l.startsWith(_json)) _log(l);
    });
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (!l.startsWith('warning:')) _log(l, error: true);
    });
    unawaited(
      proc.exitCode.then((code) {
        _log('engine exited with code $code', error: code != 0);
        if (identical(_proc, proc)) _proc = null;
      }),
    );
    final info = await call('init', [
      octprogPath,
      qwtbPath,
      p.join(apiRoot, 'compat'),
      config.packages,
    ], prelude: "addpath('${_esc(p.join(apiRoot, 'api'))}');");
    _initInfo = info;
    return info;
  }

  Future<void> stop() async {
    final pr = _proc;
    if (pr == null) return;
    _proc = null;
    _initInfo = null;
    pr.stdin.writeln('exit');
    try {
      await pr.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      pr.kill(ProcessSignal.sigkill);
    }
  }

  Future<Map<String, dynamic>> restart() async {
    await stop();
    return start();
  }

  /// Interrupts the running command (Ctrl+C) where supported, otherwise
  /// restarts the engine.
  Future<void> interrupt() async {
    final pr = _proc;
    if (pr == null) return;
    if (!Platform.isWindows && config.engine == CalcEngine.octave) {
      pr.kill(ProcessSignal.sigint);
    } else {
      pr.kill(ProcessSignal.sigkill);
      _proc = null;
      _initInfo = null;
    }
  }

  /// Executes raw code, returns its console output.
  Future<String> eval(String code, {Duration? timeout}) => _exclusive(() => _eval(code, timeout: timeout));

  /// Calls `twm_api(cmd, args...)` and returns decoded JSON result.
  Future<Map<String, dynamic>> call(String cmd, List<Object?> args, {Duration? timeout, String prelude = ''}) async {
    final a = [cmd, ...args].map(toLiteral).join(', ');
    final clear = config.clearCache ? 'clear functions; ' : '';
    final out = await eval('$prelude$clear twm_api($a);', timeout: timeout);
    for (final l in out.split('\n')) {
      if (l.startsWith(_json)) {
        final j = jsonDecode(l.substring(_json.length));
        return j is Map<String, dynamic> ? j : {'value': j};
      }
    }
    throw OctaveException('No result returned by twm_api($cmd).');
  }

  Future<T> _exclusive<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await f());
      } catch (e, s) {
        c.completeError(e, s);
      }
    });
    return c.future;
  }

  Future<String> _eval(String code, {Duration? timeout}) async {
    final pr = _proc;
    if (pr == null) throw OctaveException('Calculation engine is not running.');
    final id = ++_cmdId;
    final marker = '$_done$id';
    final out = StringBuffer();
    String? error;
    final done = Completer<void>();
    final sub = _lines.stream.listen((l) {
      if (l == marker) {
        if (!done.isCompleted) done.complete();
      } else if (l.startsWith(_err)) {
        error = l.substring(_err.length);
      } else {
        out.writeln(l);
      }
    });
    _log('>> ${code.length > 300 ? '${code.substring(0, 300)}...' : code}', command: true);
    pr.stdin.write(
      'try\n$code\ncatch __twm_e\n'
      // where in the m-code it failed (for reports of algorithm errors)
      "__twm_l = ''; if isfield(__twm_e, 'stack') && numel(__twm_e.stack) > 0, "
      "__twm_l = sprintf(' [%s:%d]', __twm_e.stack(1).name, __twm_e.stack(1).line); end\n"
      "disp(['$_err' strrep(__twm_e.message, char(10), ' | ') __twm_l]);\n"
      'end\n'
      "disp('$marker'); fflush(stdout);\n",
    );
    try {
      if (timeout != null) {
        await done.future.timeout(
          timeout,
          onTimeout: () async {
            await interrupt();
            throw OctaveException('Calculation timeout (${timeout.inSeconds} s) - command interrupted.');
          },
        );
      } else {
        await Future.any([
          done.future,
          pr.exitCode.then((c) => throw OctaveException('Calculation engine terminated (code $c).')),
        ]);
      }
    } finally {
      await sub.cancel();
    }
    if (error != null) throw OctaveException(error!);
    return out.toString();
  }

  void _log(String l, {bool error = false, bool command = false}) {
    if (!_console.isClosed) _console.add(ConsoleLine(l, isError: error, isCommand: command));
  }

  Future<void> dispose() async {
    await stop();
    await _console.close();
    await _lines.close();
  }

  // ---------------------------------------------------- literal encoding --

  static String _esc(String s) => s.replaceAll("'", "''");

  /// Encodes Dart value to Octave/Matlab literal.
  static String toLiteral(Object? v) {
    if (v == null) return '[]';
    if (v is bool) return v ? 'true' : 'false';
    if (v is int) return v.toString();
    if (v is double) {
      if (v.isNaN) return 'NaN';
      if (v.isInfinite) return v > 0 ? 'Inf' : '-Inf';
      return v.toString();
    }
    if (v is String) {
      if (!v.contains('\n') && !v.contains('\r')) return "'${_esc(v)}'";
      final parts = v.replaceAll('\r', '').split('\n').map((s) => "'${_esc(s)}'");
      return '[${parts.join(' char(10) ')}]';
    }
    if (v is List) {
      if (v.every((e) => e is num)) return '[${v.map(toLiteral).join(', ')}]';
      return '{${v.map(toLiteral).join(', ')}}';
    }
    if (v is Map) {
      // structure via jsondecode keeps nested values and types
      return "jsondecode('${_esc(jsonEncode(v))}')";
    }
    throw ArgumentError('Unsupported value for Octave literal: ${v.runtimeType}');
  }
}
