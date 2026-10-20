import 'dart:async';

import 'package:flutter/material.dart';

import '../backend/server_control.dart';
import '../state/app_state.dart';
import '../widgets/fields.dart';
import '../widgets/file_browser.dart';
import '../l10n.dart';

/// TWM server panel (TWM guide figure 3.37). The original named pipe server
/// is replaced by HTTP + WebSocket API, which also serves the web UI.
Future<void> showServerDialog(BuildContext context) => showDialog(
  context: context,
  builder: (_) => AppScope(state: AppScope.read(context), child: const _ServerDialog()),
);

class _ServerDialog extends StatefulWidget {
  const _ServerDialog();
  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  String host = '127.0.0.1';
  double port = 8080;
  String token = '';
  String webRoot = '';
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) async {
      final st = AppScope.read(context);
      if (!canHostServer(st.backend)) return;
      await serverControlFor(st.backend).refresh();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    if (!canHostServer(st.backend)) {
      return AlertDialog(
        title: Text(tr('TWM server')),
        content: Text(
          'This client is connected to ${st.backend.description}.\n'
          'The server can be hosted only by the desktop application with local backend, or by the headless '
          '"twm_server" program.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
      );
    }
    final srv = serverControlFor(st.backend);
    return AlertDialog(
      title: Text(tr('TWM server')),
      content: SizedBox(
        width: 700,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                'Remote control of this TWM instance via HTTP/WebSocket API (web UI, sequencers such as '
                'Open-Z-Bridge style clients). POST /api/<method> with JSON, events on ws://host:port/events.',
              ),
            ),
            FieldRow([
              Choice<String>(
                label: tr('Listen on'),
                value: host,
                items: const ['127.0.0.1', '0.0.0.0'],
                width: 220,
                itemLabel: (h) => h == '0.0.0.0' ? tr('0.0.0.0 (all interfaces)') : tr('127.0.0.1 (this PC only)'),
                onChanged: (v) => setState(() => host = v),
              ),
              NumField(
                label: tr('Port'),
                value: port,
                integer: true,
                min: 1,
                max: 65535,
                width: 110,
                onChanged: (v) => port = v,
              ),
              TextEntry(label: tr('Access token (optional)'), value: token, width: 240, onChanged: (v) => token = v),
            ]),
            PathField(
              label: tr('Web UI folder (built "flutter build web", optional)'),
              value: webRoot,
              backend: st.backend,
              mode: BrowseMode.folder,
              onChanged: (v) => setState(() => webRoot = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.circle, color: srv.running ? Colors.green : Colors.grey, size: 16),
                const SizedBox(width: 6),
                Text(srv.running ? trf('Running on port {0}, clients: {1}', [srv.port, srv.clients]) : tr('Stopped')),
              ],
            ),
            const SizedBox(height: 8),
            MessageBox(srv.log.reversed.take(50).join('\n'), height: 140),
            if (host == '0.0.0.0' && token.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  tr(
                    'Warning: server open to the network without access token - anyone on the network can '
                    'control the instruments and read/write files.',
                  ),
                  style: TextStyle(color: Colors.orange),
                ),
              ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: srv.running
              ? () async {
                  await srv.stop();
                  setState(() {});
                }
              : null,
          child: const Text('STOP'),
        ),
        FilledButton(
          onPressed: srv.running
              ? null
              : () async {
                  try {
                    await srv.start(host: host, port: port.round(), token: token, webRoot: webRoot);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                  setState(() {});
                },
          child: const Text('START'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close (keeps running)'))),
      ],
    );
  }
}
