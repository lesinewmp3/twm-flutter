import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twm_model/twm_model.dart';

/// Original TWM repository with example correction files.
const twmRepo = '/home/e/papka_dlya_claude/src/TWM';

void main() {
  group('INFO', () {
    test('parses scalars, matrices and nested sections', () {
      const s = '''
// comment
type:: digitizer
name:: Two HP3458A dmms test
#startmatrix:: channel identifiers
  HP3458A, channel 1
  HP3458A, channel 2
#endmatrix:: channel identifiers
#startsection:: interchannel timeshift
  #startmatrix:: value
    0.00;1.37244E-06
  #endmatrix:: value
  #startsection:: primary parameter
    name:: synchronization mode
  #endsection:: primary parameter
#endsection:: interchannel timeshift
''';
      final i = Info.parse(s);
      expect(i.text('type'), 'digitizer');
      expect(i.textList('channel identifiers'), ['HP3458A, channel 1', 'HP3458A, channel 2']);
      final ts = i.section('interchannel timeshift');
      expect(ts.matrix('value'), [
        [0.0, 1.37244e-6],
      ]);
      expect(ts.section('primary parameter').text('name'), 'synchronization mode');
      // keys of subsections are not visible at top level
      expect(i.hasKey('name'), isTrue);
      expect(() => i.text('nonexistent'), throwsA(isA<InfoException>()));
    });

    test('trailing semicolons and quoted cells', () {
      final i = Info.parse('''
#startmatrix:: files
  RAW\\G0001-A0001.mat;
  RAW\\G0001-A0002.mat;
#endmatrix:: files
#startmatrix:: q
  "a;b"; "say ""hi"""
#endmatrix:: q
''');
      expect(i.textList('files'), ['RAW\\G0001-A0001.mat', 'RAW\\G0001-A0002.mat']);
      expect(i.textMatrix('q'), [
        ['a;b', 'say "hi"'],
      ]);
    });

    test('round trip of generated document', () {
      final g = Info()
        ..setNumber('repetitions count', 3)
        ..setMatrix('gains', [
          [1e-9, 2.5e-9],
          [1.0, 0.5],
        ])
        ..setTextList('files', ['RAW\\a.mat', 'x;y']);
      final root = Info()
        ..setNumber('groups count', 1)
        ..setSection('measurement group 1', g);
      final back = Info.parse(root.toString());
      final bg = back.section('measurement group 1');
      expect(bg.number('repetitions count'), 3);
      expect(bg.matrix('gains'), [
        [1e-9, 2.5e-9],
        [1.0, 0.5],
      ]);
      expect(bg.textList('files'), ['RAW\\a.mat', 'x;y']);
    });

    test('parses all correction files of TWM repository', () {
      final files = Directory(
        '$twmRepo/data/corrections',
      ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.info'));
      expect(files, isNotEmpty);
      for (final f in files) {
        final i = Info.parse(f.readAsStringSync(encoding: latin1));
        expect(i.text('type'), isIn(['shunt', 'divider', 'digitizer', 'channel']), reason: f.path);
        // serialization must be parseable again with the same content
        final again = Info.parse(i.toString());
        expect(again.text('type'), i.text('type'));
      }
    });

    test('qwtb_list.info', () {
      final i = Info.parse(File('$twmRepo/octprog/qwtb_list.info').readAsStringSync());
      expect(i.textList('list of supported algorithms'), contains('TWM-PWRTDI'));
      expect(i.section('TWM-LowZ').textMatrix('number formats').first.first, 'f');
    });
  });

  group('CSV', () {
    test('repository table', () {
      final s = CsvSheet.parse(
        File('$twmRepo/data/corrections/transducers/shunt_100mA113/csv/tfer_gain.csv').readAsStringSync(),
      );
      expect(s.cell(0, 0), 'Gain tfer');
      expect(s.cell(1, 1), 'gain');
      expect(s.cell(3, 0), '0');
      expect(s.cols, 3);
    });

    test('template 2D', () {
      final t = CsvSheet.template(
        description: 'amp tfer',
        yAxis: 'f',
        xAxis: 'rms',
        quantities: ['gain', 'u(gain)'],
        xCount: 2,
      );
      expect(t.cells[1], ['', 'gain', 'gain', 'u(gain)', 'u(gain)']);
      expect(t.cell(2, 0), 'f \\ rms');
      expect(CsvSheet.parse(t.toString()).cell(1, 3), 'u(gain)');
    });

    test('decimal comma fix', () {
      final s = CsvSheet([
        ['1,5', 'a,b', '2'],
      ])..fixDecimalSeparators();
      expect(s.cells.first, ['1.5', 'a,b', '2']);
    });
  });

  group('MAT v4', () {
    test('encode/decode int16 channel-row matrix', () {
      // 2 channels x 3 samples, column-major: (ch1,ch2) per sample
      final y = Int16List.fromList([1, -1, 2, -2, 3, -3]);
      final bytes = MatV4.encode([MatVariable('y', 2, 3, MatPrecision.int16, y)]);
      expect(bytes.length, 20 + 2 + 12);
      final v = MatV4.decode(bytes).single;
      expect(v.name, 'y');
      expect(v.rows, 2);
      expect(v.cols, 3);
      expect(v.row(1).toList(), [-1.0, -2.0, -3.0]);
      expect(v.row(0, gain: 0.5, offset: 1).toList(), [1.5, 2.0, 2.5]);
    });

    test('multiple variables, filtered decode', () {
      final bytes = MatV4.encode([
        MatVariable.float64('a', 1, 1, Float64List.fromList([3.5])),
        MatVariable('b', 1, 2, MatPrecision.int32, Int32List.fromList([7, 8])),
      ]);
      final v = MatV4.decode(bytes, only: {'b'}).single;
      expect(v.at(0, 1), 8);
    });
  });
}
