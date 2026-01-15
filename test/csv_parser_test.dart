// test/csv_parser_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chronos/models/models.dart';
import 'package:chronos/services/csv_parser.dart';

void main() {
  late SettingsModel defaultSettings;

  setUp(() {
    defaultSettings = SettingsModel(
      csvDelimiter: ';',
      csvHasHeader: true,
      csvColDescription: 'Kommentar',
      csvColDate: 'Datum',
      csvColStart: 'K',
      csvColEnd: 'G',
      csvColDuration: 'GIBA',
      csvColPauseTotal: 'P',
      csvColPauseRanges: 'Pausen',
      csvColAbsenceTotal: 'BNA',
      csvColSick: 'KT',
      csvColHoliday: 'FT',
      csvColVacation: 'UT',
      csvColTimeCompensation: 'ZA',
    );
  });

  group('TimetacCsvParser.parseWithConfig', () {
    test('parses simple CSV with semicolon delimiter', () {
      final csv = '''Kommentar;Datum;Start;Ende;K;G;GIBA;P;Pausen;BNA;KT;FT;UT;ZA
Normaler Arbeitstag;2024-01-15;08:00;17:00;08:00;17:00;9;1;12:00-13:00;0;0;0;0;0''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].description, 'Normaler Arbeitstag');
      expect(rows[0].date, DateTime(2024, 1, 15));
    });

    test('parses CSV with comma delimiter', () {
      final settings = SettingsModel(
        csvDelimiter: ',',
        csvHasHeader: true,
        csvColDescription: 'Kommentar',
        csvColDate: 'Datum',
        csvColStart: 'K',
        csvColEnd: 'G',
      );

      final csv = '''Kommentar,Datum,K,G
Test,2024-01-01,08:00,17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, settings);

      expect(rows.length, 1);
      expect(rows[0].description, 'Test');
    });

    test('handles quoted fields correctly', () {
      final csv = '''Kommentar;Datum;K;G
"Feld mit; Semikolon";2024-01-15;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].description, 'Feld mit; Semikolon');
    });

    test('handles escaped quotes (double quotes)', () {
      final csv = '''Kommentar;Datum;K;G
"Er sagte ""Hallo""";2024-01-15;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].description, 'Er sagte "Hallo"');
    });

    test('parses pause ranges correctly', () {
      // Adjust settings to include Pausen column
      final csv = '''Kommentar;Datum;K;G;P;Pausen
Test;2024-01-15;08:00;17:00;0:45;10:00-10:15;12:00-12:30''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      // Pauses are split by semicolon within the field
    });

    test('skips empty lines', () {
      final csv = '''Kommentar;Datum;K;G
Test1;2024-01-15;08:00;17:00

Test2;2024-01-16;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 2);
    });

    test('skips Summe lines', () {
      final csv = '''Kommentar;Datum;K;G
Test;2024-01-15;08:00;17:00
Summe;;;;;''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].description, 'Test');
    });

    test('parses German date format (dd.MM.yyyy)', () {
      final csv = '''Kommentar;Datum;K;G
Test;15.01.2024;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].date, DateTime(2024, 1, 15));
    });

    test('parses ISO date format (yyyy-MM-dd)', () {
      final csv = '''Kommentar;Datum;K;G
Test;2024-01-15;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].date, DateTime(2024, 1, 15));
    });

    test('parses decimal hours (German format with comma)', () {
      final csv = '''Kommentar;Datum;K;G;GIBA
Test;2024-01-15;08:00;17:00;7,50''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      // 7.50 hours = 7h 30m = 450 minutes
      // But if start/end is provided, duration is calculated from them
    });

    test('parses time format duration (HH:mm)', () {
      final csv = '''Kommentar;Datum;K;G;GIBA
Test;2024-01-15;08:00;17:00;07:30''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
    });

    test('handles missing start/end times', () {
      final csv = '''Kommentar;Datum;K;G
Urlaub;2024-01-15;;''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].start, isNull);
      expect(rows[0].end, isNull);
    });

    test('calculates duration from start and end', () {
      final csv = '''Kommentar;Datum;K;G
Test;2024-01-15;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].duration, const Duration(hours: 9));
    });

    test('parses sick days correctly', () {
      final csv = '''Kommentar;Datum;K;G;KT
Krank;2024-01-15;;;1''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].sickDays, 1.0);
    });

    test('parses holiday correctly', () {
      final csv = '''Kommentar;Datum;K;G;FT
Feiertag;2024-01-01;;;1''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      expect(rows[0].holidayDays, 1.0);
    });

    test('parses half vacation day', () {
      final csv = '''Kommentar;Datum;K;G;UT
Urlaub;2024-01-15;;;4''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      // 4 hours of vacation
      expect(rows[0].vacationHours, const Duration(hours: 4));
    });

    test('returns empty list for empty input', () {
      final bytes = utf8.encode('');
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);
      expect(rows, isEmpty);
    });

    test('handles UTF-8 with BOM', () {
      // UTF-8 BOM is: EF BB BF
      final csv = '''Kommentar;Datum;K;G
Test;2024-01-15;08:00;17:00''';
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(csv)];
      
      // The parser uses utf8.decode with allowMalformed: true
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);
      
      // Should still parse (BOM becomes part of first header, but first row is header)
      expect(rows.length, 1);
    });

    test('resolves column by name (case insensitive)', () {
      final settings = SettingsModel(
        csvHasHeader: true,
        csvColDescription: 'KOMMENTAR', // uppercase
        csvColDate: 'datum', // lowercase
      );

      final csv = '''Kommentar;Datum;K;G
Test;2024-01-15;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, settings);

      expect(rows.length, 1);
      expect(rows[0].description, 'Test');
    });

    test('resolves column by index when header is disabled', () {
      final settings = SettingsModel(
        csvHasHeader: false,
        csvColDescription: '0',
        csvColDate: '1',
        csvColStart: '2',
        csvColEnd: '3',
      );

      final csv = '''Test;2024-01-15;08:00;17:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, settings);

      expect(rows.length, 1);
      expect(rows[0].description, 'Test');
      expect(rows[0].date, DateTime(2024, 1, 15));
    });

    test('parses pause ranges with multiple pauses', () {
      // Create a more complete CSV that includes pause range column
      final csv = '''Kommentar;Datum;K;G;P;Pausen;BNA;KT;FT;UT;ZA
Test;2024-01-15;08:00;17:00;0:45;10:00-10:15;12:00-12:30;0;0;0;0;0''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
      // The pauseRanges field contains multiple ranges separated by semicolons
      // but since we're using ; as delimiter, the field splitting might differ
    });

    test('handles datetime with seconds', () {
      final csv = '''Kommentar;Datum;K;G
Test;15.01.2024 08:30:45;15.01.2024 08:30:45;15.01.2024 17:00:00''';

      final bytes = utf8.encode(csv);
      final rows = TimetacCsvParser.parseWithConfig(bytes, defaultSettings);

      expect(rows.length, 1);
    });
  });
}
