/// Catalog of correction items of TWM/TPQA correction files (names and
/// table layouts taken from `correction_load_transducer.m` and
/// `correction_load_digitizer.m`; meaning from "TWM Corrections Reference
/// Manual").
library;

import '../csv_sheet.dart';

/// Correction item stored as a CSV table referenced from the INFO file.
class CsvItem {
  /// INFO key (transducers) or section name (digitizer/channel).
  final String key;
  final String title;
  final String yAxis; // primary axis quantity ('' = none)
  final String xAxis; // secondary axis ('' = 1D table)
  final List<String> quantities;
  final String description;

  const CsvItem(this.key, this.title, this.yAxis, this.xAxis, this.quantities, this.description);

  bool get is2d => xAxis.isNotEmpty;

  CsvSheet template({int xCount = 1, int yCount = 3}) => CsvSheet.template(
    description: title,
    yAxis: yAxis,
    xAxis: is2d ? xAxis : null,
    quantities: quantities,
    xCount: is2d ? xCount : 1,
    yCount: yCount,
  );
}

/// Digitizer/channel correction section (INFO section with value and
/// uncertainty matrices, or CSV paths for table corrections).
class SectionItem {
  final String name;
  final String title;
  final bool channel; // channel correction (otherwise digitizer level)
  final CsvItem? table; // when stored as CSV table(s)
  final List<String> quantities; // numeric quantities (value, uncertainty)
  final String description;
  const SectionItem(
    this.name,
    this.title, {
    required this.channel,
    this.table,
    this.quantities = const [],
    required this.description,
  });
}

class CorrectionCatalog {
  static const transducerItems = <CsvItem>[
    CsvItem(
      'amplitude transfer path',
      'Amplitude transfer',
      'f',
      'rms',
      ['gain', 'u_gain'],
      'Relative frequency/level dependence of the transducer ratio (input/output), multiplied by '
          'the nominal ratio. y-axis: frequency [Hz], x-axis: input RMS value [V or A].',
    ),
    CsvItem('phase transfer path', 'Phase transfer', 'f', 'rms', [
      'phi',
      'u_phi',
    ], 'Phase shift input-output [rad]. y-axis: frequency [Hz], x-axis: input RMS value.'),
    CsvItem('sfdr path', 'SFDR', 'f', 'rms', [
      'sfdr',
    ], 'Spurious free dynamic range [dB]. y-axis: fundamental frequency, x-axis: fundamental amplitude.'),
    CsvItem('output terminals series impedance path', 'Output terminals series impedance (high side)', 'f', '', [
      'Rs',
      'Ls',
      'u_Rs',
      'u_Ls',
    ], 'Loading correction: series impedance of transducer high-side terminal.'),
    CsvItem(
      'output terminals series impedance path (low-side)',
      'Output terminals series impedance (low side)',
      'f',
      '',
      ['Rs', 'Ls', 'u_Rs', 'u_Ls'],
      'Loading correction: series impedance of transducer low-side terminal.',
    ),
    CsvItem('output terminals mutual inductance path', 'Output terminals mutual inductance', 'f', '', [
      'M',
      'u_M',
    ], 'Loading correction: mutual inductance between output terminals.'),
    CsvItem('output terminals shunting admittance path', 'Output terminals shunting admittance', 'f', '', [
      'Cp',
      'D',
      'u_Cp',
      'u_D',
    ], 'Loading correction: loss admittance between terminals (Cp, D).'),
    CsvItem('output cable series impedance path', 'Output cable series impedance', 'f', '', [
      'Rs',
      'Ls',
      'u_Rs',
      'u_Ls',
    ], 'Loading correction: series impedance of the cable to the digitizer.'),
    CsvItem('output cable shunting admittance path', 'Output cable shunting admittance', 'f', '', [
      'Cp',
      'D',
      'u_Cp',
      'u_D',
    ], 'Loading correction: shunting admittance of the cable to the digitizer.'),
    CsvItem('rvd low side impedance path', 'RVD low side impedance', 'f', '', [
      'Rp',
      'Cp',
      'u_Rp',
      'u_Cp',
    ], 'Impedance of the low-side resistor of a resistive voltage divider (needed for loading correction).'),
    CsvItem('buffer output series impedance path', 'Buffer output series impedance', 'f', '', [
      'Rs',
      'Ls',
      'u_Rs',
      'u_Ls',
    ], 'Optional output buffer series impedance.'),
  ];

  static const digitizerItems = <SectionItem>[
    SectionItem(
      'interchannel timeshift',
      'Interchannel time shift',
      channel: false,
      quantities: ['its', 'u_its'],
      description:
          'Time shift of each channel relative to the first one [s]: row vector, one value per '
          'channel (first is always 0).',
    ),
    SectionItem(
      'timebase correction',
      'Timebase correction',
      channel: false,
      quantities: ['tbc', 'u_tbc'],
      description: 'Relative correction of the sampling timebase (fs_real = fs*(1+tbc)).',
    ),
  ];

  static const channelItems = <SectionItem>[
    SectionItem(
      'nominal gain',
      'Nominal gain',
      channel: true,
      quantities: ['gain', 'u_gain'],
      description:
          'DC gain correction of the channel (measured = gain*indicated). Typically depends on '
          'primary parameter "voltage ranges [V]".',
    ),
    SectionItem(
      'gain transfer',
      'Gain frequency transfer',
      channel: true,
      table: CsvItem('gain transfer', 'Gain transfer', 'f', 'amp', [
        'gain',
        'u_gain',
      ], 'Relative gain frequency/amplitude dependence. y-axis: frequency [Hz], x-axis: amplitude [V].'),
      description: 'Relative frequency dependence of the gain (CSV table), multiplied by nominal gain.',
    ),
    SectionItem(
      'phase transfer',
      'Phase frequency transfer',
      channel: true,
      table: CsvItem('phase transfer', 'Phase transfer', 'f', 'amp', [
        'phi',
        'u_phi',
      ], 'Phase frequency dependence [rad]. y-axis: frequency [Hz], x-axis: amplitude [V].'),
      description: 'Phase error frequency dependence of the channel (CSV table).',
    ),
    SectionItem(
      'dc offset',
      'DC offset',
      channel: true,
      quantities: ['ofs', 'u_ofs'],
      description: 'DC offset of the channel [V].',
    ),
    SectionItem(
      'aperture correction',
      'Aperture correction',
      channel: true,
      quantities: ['enab'],
      description: 'Enables (1) correction of the ADC aperture effect (sinc). Enabled by default.',
    ),
    SectionItem(
      'sfdr',
      'SFDR',
      channel: true,
      table: CsvItem('sfdr', 'SFDR', 'f', 'amp', ['sfdr'], 'SFDR [dB]. y-axis: frequency, x-axis: amplitude.'),
      description: 'Spurious free dynamic range of the channel [dB] (CSV table).',
    ),
    SectionItem(
      'rms jitter',
      'RMS jitter',
      channel: true,
      quantities: ['jitt'],
      description: 'RMS jitter of the sampling clock [s].',
    ),
    SectionItem(
      'input admittance',
      'Input admittance',
      channel: true,
      table: CsvItem('input admittance', 'Input admittance', 'f', '', [
        'Cp',
        'Gp',
        'u_Cp',
        'u_Gp',
      ], 'Input admittance of the channel. y-axis: frequency [Hz], Cp [F], Gp [S].'),
      description: 'Input admittance (loading of the transducers), CSV table.',
    ),
  ];

  static CsvItem? transducerItem(String key) {
    for (final i in transducerItems) {
      if (i.key == key) return i;
    }
    return null;
  }

  static SectionItem? sectionItem(String name) {
    for (final i in [...digitizerItems, ...channelItems]) {
      if (i.name == name) return i;
    }
    return null;
  }
}
