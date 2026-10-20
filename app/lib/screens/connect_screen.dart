import 'package:flutter/material.dart';

import '../l10n.dart';

/// Start screen: connecting to the backend (web: TWM server address).
class ConnectScreen extends StatefulWidget {
  final Object? error;
  final bool canLocal;
  final void Function(String? url) onConnect;
  const ConnectScreen({super.key, this.error, required this.onConnect, required this.canLocal});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _url = TextEditingController(text: Uri.base.hasAuthority ? Uri.base.origin : 'http://127.0.0.1:8080');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(tr('TWM - TracePQM Wattmeter'), style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      'Connect to a TWM server (the PC with digitizers and GNU Octave). '
                      'Start it there with: dart run twm_core:twm_server --host 0.0.0.0',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _url,
                    decoration: InputDecoration(labelText: tr('Server address')),
                    onSubmitted: widget.onConnect,
                  ),
                  const SizedBox(height: 16),
                  if (widget.error != null)
                    Text('${widget.error}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (widget.canLocal)
                        TextButton(onPressed: () => widget.onConnect(null), child: Text(tr('Use local backend'))),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: () => widget.onConnect(_url.text), child: Text(tr('Connect'))),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
