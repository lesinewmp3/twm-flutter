import 'package:flutter/material.dart';

import 'backend/backend_factory.dart';
import 'screens/connect_screen.dart';
import 'screens/main_screen.dart';
import 'state/app_state.dart';

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
    if (canRunLocalBackend) _connect(null);
  }

  Future<void> _connect(String? url) async {
    setState(() => _error = null);
    try {
      final b = await createBackend(serverUrl: url);
      final s = await AppState.create(b);
      setState(() => _state = s);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF2E5C8A);
    return MaterialApp(
      title: 'TWM - TracePQM Wattmeter',
      debugShowCheckedModeBanner: false,
      themeMode: _mode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        visualDensity: VisualDensity.compact,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        visualDensity: VisualDensity.compact,
        useMaterial3: true,
      ),
      home: _state == null
          ? ConnectScreen(error: _error, onConnect: _connect, canLocal: canRunLocalBackend)
          : AppScope(
              state: _state!,
              child: MainScreen(
                onToggleTheme: () =>
                    setState(() => _mode = _mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light),
              ),
            ),
    );
  }
}
