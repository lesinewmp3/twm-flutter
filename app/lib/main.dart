import 'package:flutter/material.dart';

import 'backend/backend_factory.dart';
import 'l10n.dart';
import 'screens/connect_screen.dart';
import 'screens/main_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TwmApp());
}

class TwmApp extends StatefulWidget {
  const TwmApp({super.key});

  @override
  State<TwmApp> createState() => _TwmAppState();
}

class _TwmAppState extends State<TwmApp> {
  AppState? _state;
  Object? _error;
  ThemeMode _mode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    L10n.apply('auto');
    if (canRunLocalBackend) _connect(null);
  }

  Future<void> _connect(String? url) async {
    setState(() => _error = null);
    try {
      final b = await createBackend(serverUrl: url);
      final s = await AppState.create(b);
      L10n.apply(s.settings.language);
      s.addListener(_onState);
      setState(() => _state = s);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  String _lang = '';

  void _onState() {
    final l = _state!.settings.language;
    if (l != _lang) {
      _lang = l;
      L10n.apply(l);
      setState(() {}); // rebuild whole tree with the new language
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TWM - TracePQM Wattmeter',
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      theme: TwmTheme.light(),
      darkTheme: TwmTheme.dark(),
      home: _state == null
          ? (canRunLocalBackend && _error == null
                ? const Scaffold(body: Center(child: CircularProgressIndicator()))
                : ConnectScreen(error: _error, onConnect: _connect, canLocal: canRunLocalBackend))
          : AppScope(
              key: ValueKey(_lang),
              state: _state!,
              child: MainScreen(
                onToggleTheme: () =>
                    setState(() => _mode = _mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light),
              ),
            ),
    );
  }
}
