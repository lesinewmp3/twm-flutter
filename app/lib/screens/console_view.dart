import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../widgets/fields.dart';

/// GNU Octave / Matlab console (GOLPI console window of TWM) with command
/// entry for debugging.
class ConsoleView extends StatefulWidget {
  const ConsoleView({super.key});
  @override
  State<ConsoleView> createState() => _ConsoleViewState();
}

class _ConsoleViewState extends State<ConsoleView> {
  final _cmd = TextEditingController();
  final _scroll = ScrollController();
  final _history = <String>[];
  bool _busy = false;

  Future<void> _run() async {
    final st = AppScope.read(context);
    final c = _cmd.text.trim();
    if (c.isEmpty) return;
    _history.add(c);
    _cmd.clear();
    setState(() => _busy = true);
    try {
      await st.backend.octaveStart(st.settings.octave);
      await st.backend.octaveEval(c);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _cmd.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.all(8),
              child: SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: st.console.length,
                  itemBuilder: (_, i) {
                    final l = st.console[i];
                    return Text(
                      l.text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: l.isError ? Colors.redAccent : (l.isCommand ? Colors.cyanAccent : Colors.white70),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cmd,
                  enabled: !_busy,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Octave/Matlab command',
                    prefixText: '>> ',
                  ),
                  onSubmitted: (_) => _run(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _busy ? null : _run, child: const Text('Run')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: st.clearConsole, child: const Text('Clear')),
            ],
          ),
        ],
      ),
    );
  }
}
