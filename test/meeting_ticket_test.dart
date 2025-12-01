import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_jira_timetac/main.dart';
import 'package:flutter_jira_timetac/models/models.dart';

void main() {
  group('resolveMeetingIssueKeyForTitle', () {
    late AppState appState;

    setUp(() {
      appState = AppState();
      appState.settings = SettingsModel();
      appState.settings.meetingIssueKey = 'DEFAULT-1';
    });

    test('returns ticket from title if present at start', () {
      expect(appState.resolveMeetingIssueKeyForTitle('PROJ-123: Meeting'), 'PROJ-123');
      expect(appState.resolveMeetingIssueKeyForTitle('[PROJ-123] Meeting'), 'PROJ-123');
      expect(appState.resolveMeetingIssueKeyForTitle('PROJ-123 Meeting'), 'PROJ-123');
      expect(appState.resolveMeetingIssueKeyForTitle('PROJ-123'), 'PROJ-123');
    });

    test('returns ticket from title case insensitive', () {
      expect(appState.resolveMeetingIssueKeyForTitle('proj-123: Meeting'), 'PROJ-123');
    });

    test('returns default if no ticket at start', () {
      expect(appState.resolveMeetingIssueKeyForTitle('Meeting with PROJ-123 inside'), 'DEFAULT-1');
      expect(appState.resolveMeetingIssueKeyForTitle('Daily Standup'), 'DEFAULT-1');
    });

    test('respects meeting rules if no ticket at start', () {
      appState.settings.meetingRules = [
        MeetingRule(pattern: 'Standup', issueKey: 'MEET-1'),
      ];
      expect(appState.resolveMeetingIssueKeyForTitle('Daily Standup'), 'MEET-1');
    });

    test('ticket at start takes precedence over rules', () {
      appState.settings.meetingRules = [
        MeetingRule(pattern: 'Standup', issueKey: 'MEET-1'),
      ];
      expect(appState.resolveMeetingIssueKeyForTitle('PROJ-999: Daily Standup'), 'PROJ-999');
    });
  });
}
