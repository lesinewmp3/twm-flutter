import 'package:flutter/material.dart';

/// About box.
void showTwmAbout(BuildContext context) => showAboutDialog(
  context: context,
  applicationName: 'TWM / TPQA (Flutter)',
  applicationVersion: '0.1.0',
  applicationLegalese:
      'Port of TWM - TracePQM Wattmeter (S. Maslan, CMI) and TPQA - Traceable Power & PQ '
      'Analyzer (B. Trinchera, INRIM), EMPIR project 15RPT04 TracePQM. MIT license. '
      'Processing algorithms: QWTB toolbox (algorithms have their own licenses).',
  children: const [
    SizedBox(height: 12),
    Text(
      'Original projects:\n  https://github.com/smaslan/TWM\n  https://github.com/btrinchera/TPQA\n'
      '  https://qwtb.github.io/qwtb/',
    ),
    SizedBox(height: 8),
    Text(
      'Hardware drivers of this port were written from the instrument documentation and were NOT tested '
      'on real hardware. Validate before metrological use.',
    ),
  ],
);
