// test/models_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:chronos/models/models.dart';

void main() {
  group('TimeRange', () {
    test('calculates duration correctly', () {
      final range = TimeRange(
        DateTime(2024, 1, 1, 10, 0),
        DateTime(2024, 1, 1, 10, 30),
      );
      expect(range.duration, const Duration(minutes: 30));
    });

    test('handles negative duration (end before start)', () {
      final range = TimeRange(
        DateTime(2024, 1, 1, 10, 30),
        DateTime(2024, 1, 1, 10, 0),
      );
      // Duration should be negative
      expect(range.duration.isNegative, true);
    });

    test('zero duration when start equals end', () {
      final now = DateTime(2024, 1, 1, 10, 0);
      final range = TimeRange(now, now);
      expect(range.duration, Duration.zero);
    });
  });

  group('TimetacRow', () {
    test('creates with all required fields', () {
      final row = TimetacRow(
        description: 'Normaler Arbeitstag',
        date: DateTime(2024, 1, 15),
        start: DateTime(2024, 1, 15, 8, 0),
        end: DateTime(2024, 1, 15, 17, 0),
        duration: const Duration(hours: 9),
      );

      expect(row.description, 'Normaler Arbeitstag');
      expect(row.date, DateTime(2024, 1, 15));
      expect(row.start, DateTime(2024, 1, 15, 8, 0));
      expect(row.end, DateTime(2024, 1, 15, 17, 0));
      expect(row.duration, const Duration(hours: 9));
    });

    test('defaults pauses to empty list', () {
      final row = TimetacRow(
        description: '',
        date: DateTime(2024, 1, 1),
        start: null,
        end: null,
        duration: Duration.zero,
      );
      expect(row.pauses, isEmpty);
    });

    test('defaults all optional durations to zero', () {
      final row = TimetacRow(
        description: '',
        date: DateTime(2024, 1, 1),
        start: null,
        end: null,
        duration: Duration.zero,
      );
      expect(row.pauseTotal, Duration.zero);
      expect(row.absenceTotal, Duration.zero);
      expect(row.sickDays, 0.0);
      expect(row.holidayDays, 0.0);
      expect(row.vacationHours, Duration.zero);
      expect(row.timeCompensationHours, Duration.zero);
    });

    test('stores pauses correctly', () {
      final pauses = [
        TimeRange(DateTime(2024, 1, 1, 12, 0), DateTime(2024, 1, 1, 12, 30)),
        TimeRange(DateTime(2024, 1, 1, 15, 0), DateTime(2024, 1, 1, 15, 15)),
      ];
      final row = TimetacRow(
        description: '',
        date: DateTime(2024, 1, 1),
        start: DateTime(2024, 1, 1, 8, 0),
        end: DateTime(2024, 1, 1, 17, 0),
        duration: const Duration(hours: 9),
        pauses: pauses,
        pauseTotal: const Duration(minutes: 45),
      );
      
      expect(row.pauses.length, 2);
      expect(row.pauseTotal, const Duration(minutes: 45));
    });
  });

  group('SettingsModel', () {
    test('has sensible defaults', () {
      final settings = SettingsModel();
      
      expect(settings.csvDelimiter, ';');
      expect(settings.csvHasHeader, true);
      expect(settings.gitlabLookbackDays, 30);
      expect(settings.noGitlabAccount, false);
      expect(settings.meetingRules, isEmpty);
      expect(settings.titleReplacementRules, isEmpty);
    });

    test('default non-meeting hints list is populated', () {
      final settings = SettingsModel();
      expect(settings.nonMeetingHintsList, isNotEmpty);
      expect(settings.nonMeetingHintsList, contains('homeoffice'));
      expect(settings.nonMeetingHintsList, contains('focus'));
    });

    test('toJson serializes all fields', () {
      final settings = SettingsModel(
        meetingIssueKey: 'MEET-1',
        fallbackIssueKey: 'DEV-1',
        jiraBaseUrl: 'https://jira.example.com',
        jiraEmail: 'test@example.com',
        jiraApiToken: 'secret',
        csvDelimiter: ',',
        csvHasHeader: false,
        gitlabLookbackDays: 60,
        noGitlabAccount: true,
      );

      final json = settings.toJson();

      expect(json['meetingIssueKey'], 'MEET-1');
      expect(json['fallbackIssueKey'], 'DEV-1');
      expect(json['jiraBaseUrl'], 'https://jira.example.com');
      expect(json['jiraEmail'], 'test@example.com');
      expect(json['jiraApiToken'], 'secret');
      expect(json['csvDelimiter'], ',');
      expect(json['csvHasHeader'], false);
      expect(json['gitlabLookbackDays'], 60);
      expect(json['noGitlabAccount'], true);
    });

    test('fromJson deserializes all fields', () {
      final json = {
        'meetingIssueKey': 'MEET-2',
        'fallbackIssueKey': 'DEV-2',
        'jiraBaseUrl': 'https://jira2.example.com',
        'jiraEmail': 'test2@example.com',
        'jiraApiToken': 'secret2',
        'csvDelimiter': ',',
        'csvHasHeader': false,
        'gitlabLookbackDays': 45,
        'noGitlabAccount': true,
      };

      final settings = SettingsModel.fromJson(json);

      expect(settings.meetingIssueKey, 'MEET-2');
      expect(settings.fallbackIssueKey, 'DEV-2');
      expect(settings.jiraBaseUrl, 'https://jira2.example.com');
      expect(settings.jiraEmail, 'test2@example.com');
      expect(settings.jiraApiToken, 'secret2');
      expect(settings.csvDelimiter, ',');
      expect(settings.csvHasHeader, false);
      expect(settings.gitlabLookbackDays, 45);
      expect(settings.noGitlabAccount, true);
    });

    test('fromJson handles missing fields gracefully', () {
      final settings = SettingsModel.fromJson({});

      expect(settings.meetingIssueKey, '');
      expect(settings.jiraBaseUrl, '');
      expect(settings.csvDelimiter, ';');
      expect(settings.csvHasHeader, false); // default is false from JSON
      expect(settings.gitlabLookbackDays, 30);
      expect(settings.noGitlabAccount, false);
    });

    test('toJson and fromJson round-trip preserves data', () {
      final original = SettingsModel(
        meetingIssueKey: 'ROUNDTRIP-1',
        jiraBaseUrl: 'https://test.com',
        csvDelimiter: '|',
        gitlabLookbackDays: 99,
        meetingRules: [
          MeetingRule(pattern: '1:1', issueKey: 'MGMT-1'),
        ],
        titleReplacementRules: [
          TitleReplacementRule(triggerWord: 'Test', replacements: ['A', 'B']),
        ],
      );

      final json = original.toJson();
      final restored = SettingsModel.fromJson(json);

      expect(restored.meetingIssueKey, original.meetingIssueKey);
      expect(restored.jiraBaseUrl, original.jiraBaseUrl);
      expect(restored.csvDelimiter, original.csvDelimiter);
      expect(restored.gitlabLookbackDays, original.gitlabLookbackDays);
      expect(restored.meetingRules.length, 1);
      expect(restored.meetingRules.first.pattern, '1:1');
      expect(restored.titleReplacementRules.length, 1);
      expect(restored.titleReplacementRules.first.triggerWord, 'Test');
    });

    test('nonMeetingHintsList parses multiline correctly', () {
      final settings = SettingsModel(
        nonMeetingHintsMultiline: 'homeoffice\nfocus\n  TRAVEL  \n\nreise',
      );

      final list = settings.nonMeetingHintsList;
      expect(list, contains('homeoffice'));
      expect(list, contains('focus'));
      expect(list, contains('travel')); // trimmed and lowercased
      expect(list, contains('reise'));
      expect(list.length, 4); // empty line filtered out
    });

    test('restoreDefaultNonMeetingHints resets to defaults', () {
      final settings = SettingsModel(
        nonMeetingHintsMultiline: 'custom\nhints',
      );
      
      settings.restoreDefaultNonMeetingHints();
      
      expect(settings.nonMeetingHintsList, contains('homeoffice'));
      expect(settings.nonMeetingHintsList, isNot(contains('custom')));
    });
  });

  group('MeetingRule', () {
    test('creates with required fields', () {
      final rule = MeetingRule(pattern: 'Daily', issueKey: 'SCRUM-1');
      expect(rule.pattern, 'Daily');
      expect(rule.issueKey, 'SCRUM-1');
    });

    test('toJson serializes correctly', () {
      final rule = MeetingRule(pattern: 'Retro', issueKey: 'SCRUM-2');
      final json = rule.toJson();
      
      expect(json['pattern'], 'Retro');
      expect(json['issueKey'], 'SCRUM-2');
    });

    test('fromJson deserializes correctly', () {
      final rule = MeetingRule.fromJson({
        'pattern': 'Sprint Planning',
        'issueKey': 'SCRUM-3',
      });
      
      expect(rule.pattern, 'Sprint Planning');
      expect(rule.issueKey, 'SCRUM-3');
    });

    test('fromJson handles missing fields', () {
      final rule = MeetingRule.fromJson({});
      expect(rule.pattern, '');
      expect(rule.issueKey, '');
    });

    test('round-trip preserves data', () {
      final original = MeetingRule(pattern: 'Test', issueKey: 'TEST-1');
      final restored = MeetingRule.fromJson(original.toJson());
      
      expect(restored.pattern, original.pattern);
      expect(restored.issueKey, original.issueKey);
    });
  });

  group('TitleReplacementRule', () {
    test('creates with required fields', () {
      final rule = TitleReplacementRule(
        triggerWord: 'Abstimmung',
        replacements: ['Technische Abstimmung', 'Fachliche Abstimmung'],
      );
      
      expect(rule.triggerWord, 'Abstimmung');
      expect(rule.replacements.length, 2);
    });

    test('toJson serializes correctly', () {
      final rule = TitleReplacementRule(
        triggerWord: 'Meeting',
        replacements: ['Tech Meeting'],
      );
      final json = rule.toJson();
      
      expect(json['triggerWord'], 'Meeting');
      expect(json['replacements'], ['Tech Meeting']);
    });

    test('fromJson deserializes correctly', () {
      final rule = TitleReplacementRule.fromJson({
        'triggerWord': 'Call',
        'replacements': ['Customer Call', 'Sales Call'],
      });
      
      expect(rule.triggerWord, 'Call');
      expect(rule.replacements, ['Customer Call', 'Sales Call']);
    });

    test('fromJson handles missing fields', () {
      final rule = TitleReplacementRule.fromJson({});
      expect(rule.triggerWord, '');
      expect(rule.replacements, isEmpty);
    });
  });
}
