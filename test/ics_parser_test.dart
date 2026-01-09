// test/ics_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_jira_timetac/services/ics_parser.dart';

void main() {
  setUp(() {
    // Reset to default hints before each test
    setNonMeetingHints([
      'homeoffice',
      'focus',
      'reise',
    ]);
    clearIcsDayCache();
    clearIcsRangeCache();
  });

  group('parseIcs', () {
    test('parses simple event correctly', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Team Meeting
UID:event-1
ATTENDEE:mailto:user@example.com
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics, selfEmail: 'user@example.com');

      expect(result.events.length, 1);
      expect(result.events[0].summary, 'Team Meeting');
      expect(result.events[0].start, DateTime(2024, 1, 15, 10, 0));
      expect(result.events[0].end, DateTime(2024, 1, 15, 11, 0));
      expect(result.events[0].duration, const Duration(hours: 1));
    });

    test('parses all-day event correctly', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART;VALUE=DATE:20240115
DTEND;VALUE=DATE:20240116
SUMMARY:Ganztägiges Event
UID:allday-1
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].allDay, true);
      expect(result.events[0].start, DateTime(2024, 1, 15));
      expect(result.events[0].end, DateTime(2024, 1, 16));
    });

    test('parses UTC time (with Z) and converts to local', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000Z
DTEND:20240115T110000Z
SUMMARY:UTC Meeting
UID:utc-1
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      // The parsed time should be converted to local time
      expect(result.events[0].start.isUtc, false);
    });

    test('parses TZID datetime format', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART;TZID=Europe/Vienna:20240115T100000
DTEND;TZID=Europe/Vienna:20240115T110000
SUMMARY:Vienna Meeting
UID:tz-1
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].summary, 'Vienna Meeting');
    });

    test('handles folded lines (continuation with space)', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:This is a very long
 meeting title that spans multiple lines
UID:folded-1
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].summary, contains('very long'));
      expect(result.events[0].summary, contains('multiple lines'));
    });

    test('extracts attendee count', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Team Meeting
UID:attendees-1
ATTENDEE:mailto:user1@example.com
ATTENDEE:mailto:user2@example.com
ATTENDEE:mailto:user3@example.com
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].attendeeCount, 3);
    });

    test('extracts self participation status', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Team Meeting
UID:partstat-1
ATTENDEE;PARTSTAT=ACCEPTED:mailto:me@example.com
ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:other@example.com
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics, selfEmail: 'me@example.com');

      expect(result.events.length, 1);
      expect(result.events[0].selfPartstat, 'ACCEPTED');
    });

    test('parses EXDATE correctly', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Recurring Meeting
UID:exdate-1
RRULE:FREQ=DAILY;COUNT=5
EXDATE:20240116T100000
EXDATE:20240118T100000
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].exdates.length, 2);
    });

    test('parses RECURRENCE-ID for exception', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Recurring Meeting
UID:recurring-1
RRULE:FREQ=DAILY;COUNT=5
END:VEVENT
BEGIN:VEVENT
DTSTART:20240117T140000
DTEND:20240117T150000
SUMMARY:Modified occurrence
UID:recurring-1
RECURRENCE-ID:20240117T100000
STATUS:CANCELLED
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      // Should have the recurring event + the exception
      expect(result.events.length, 2);
      final exception = result.events.where((e) => e.recurrenceId != null).toList();
      expect(exception.length, 1);
    });

    test('parses STATUS field', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Cancelled Meeting
UID:status-1
STATUS:CANCELLED
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].status, 'CANCELLED');
    });

    test('parses TRANSP (transparency)', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Transparent Event
UID:transp-1
TRANSP:TRANSPARENT
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].transp, 'TRANSPARENT');
    });

    test('parses Microsoft busy status', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:OOF Event
UID:busy-1
X-MICROSOFT-CDO-BUSYSTATUS:OOF
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].busyStatus, 'OOF');
    });

    test('parses DESCRIPTION field', () {
      const ics = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20240115T100000
DTEND:20240115T110000
SUMMARY:Meeting with notes
UID:desc-1
DESCRIPTION:This is the meeting description
END:VEVENT
END:VCALENDAR''';

      final result = parseIcs(ics);

      expect(result.events.length, 1);
      expect(result.events[0].description, 'This is the meeting description');
    });
  });

  group('IcsEventFlags', () {
    test('isLikelyCancelledOrDeclined detects cancelled status', () {
      final event = IcsEvent(
        start: DateTime(2024, 1, 15, 10, 0),
        end: DateTime(2024, 1, 15, 11, 0),
        summary: 'Meeting',
        allDay: false,
        status: 'CANCELLED',
      );

      expect(event.isLikelyCancelledOrDeclined, true);
    });

    test('isLikelyCancelledOrDeclined detects abgesagt in title', () {
      final event = IcsEvent(
        start: DateTime(2024, 1, 15, 10, 0),
        end: DateTime(2024, 1, 15, 11, 0),
        summary: 'Meeting - Abgesagt',
        allDay: false,
      );

      expect(event.isLikelyCancelledOrDeclined, true);
    });

    test('isLikelyCancelledOrDeclined detects canceled in title', () {
      final event = IcsEvent(
        start: DateTime(2024, 1, 15, 10, 0),
        end: DateTime(2024, 1, 15, 11, 0),
        summary: 'Canceled: Team Meeting',
        allDay: false,
      );

      expect(event.isLikelyCancelledOrDeclined, true);
    });

    test('isLikelyCancelledOrDeclined detects declined partstat', () {
      final event = IcsEvent(
        start: DateTime(2024, 1, 15, 10, 0),
        end: DateTime(2024, 1, 15, 11, 0),
        summary: 'Meeting',
        allDay: false,
        selfPartstat: 'DECLINED',
      );

      expect(event.isLikelyCancelledOrDeclined, true);
    });

    test('isLikelyCancelledOrDeclined returns false for accepted', () {
      final event = IcsEvent(
        start: DateTime(2024, 1, 15, 10, 0),
        end: DateTime(2024, 1, 15, 11, 0),
        summary: 'Regular Meeting',
        allDay: false,
        selfPartstat: 'ACCEPTED',
      );

      expect(event.isLikelyCancelledOrDeclined, false);
    });
  });

  group('buildDayCalendarCached', () {
    test('filters out cancelled events', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Regular Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 14, 0),
          end: DateTime(2024, 1, 15, 15, 0),
          summary: 'Cancelled Meeting - Abgesagt',
          allDay: false,
          attendeeCount: 2,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 1);
      expect(day.meetings[0].summary, 'Regular Meeting');
    });

    test('filters out all-day events', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Regular Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15),
          end: DateTime(2024, 1, 16),
          summary: 'All Day Event',
          allDay: true,
          attendeeCount: 2,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 1);
      expect(day.meetings[0].summary, 'Regular Meeting');
    });

    test('filters out transparent events', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Regular Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 14, 0),
          end: DateTime(2024, 1, 15, 15, 0),
          summary: 'Tentative Block',
          allDay: false,
          transp: 'TRANSPARENT',
          attendeeCount: 2,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 1);
    });

    test('filters out events with FREE busy status', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Regular Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 14, 0),
          end: DateTime(2024, 1, 15, 15, 0),
          summary: 'Free Block',
          allDay: false,
          busyStatus: 'FREE',
          attendeeCount: 2,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 1);
    });

    test('filters out events with no attendees (non-meeting)', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Team Meeting',
          allDay: false,
          attendeeCount: 3,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 14, 0),
          end: DateTime(2024, 1, 15, 15, 0),
          summary: 'Private appointment',
          allDay: false,
          attendeeCount: 0, // No attendees = not a meeting
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 1);
      expect(day.meetings[0].summary, 'Team Meeting');
    });

    test('filters out non-meeting hints', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Team Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 8, 0),
          end: DateTime(2024, 1, 15, 17, 0),
          summary: 'Homeoffice',
          allDay: false,
          attendeeCount: 1,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 14, 0),
          end: DateTime(2024, 1, 15, 16, 0),
          summary: 'Focus Time',
          allDay: false,
          attendeeCount: 1,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 1);
      expect(day.meetings[0].summary, 'Team Meeting');
    });

    test('detects day off from all-day vacation event', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15),
          end: DateTime(2024, 1, 16),
          summary: 'Urlaub',
          allDay: true,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.dayOff, true);
      expect(day.meetings, isEmpty);
    });

    test('detects day off from all-day sick event', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15),
          end: DateTime(2024, 1, 16),
          summary: 'Krank',
          allDay: true,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.dayOff, true);
    });

    test('detects day off from OOF busy status', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15),
          end: DateTime(2024, 1, 16),
          summary: 'Out of Office',
          allDay: true,
          busyStatus: 'OOF',
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.dayOff, true);
    });

    test('sorts meetings by start time', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 14, 0),
          end: DateTime(2024, 1, 15, 15, 0),
          summary: 'Second Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'First Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 2);
      expect(day.meetings[0].summary, 'First Meeting');
      expect(day.meetings[1].summary, 'Second Meeting');
    });

    test('filters out events longer than 10 hours', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Normal Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
        IcsEvent(
          start: DateTime(2024, 1, 15, 7, 0),
          end: DateTime(2024, 1, 15, 19, 0), // 12 hours
          summary: 'All Day Work Block',
          allDay: false,
          attendeeCount: 2,
        ),
      ];

      final day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );

      expect(day.meetings.length, 1);
      expect(day.meetings[0].summary, 'Normal Meeting');
    });
  });

  group('RRULE expansion', () {
    test('expands daily recurring events', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Daily Standup',
          allDay: false,
          attendeeCount: 5,
          rrule: 'FREQ=DAILY;COUNT=3',
          uid: 'daily-1',
        ),
      ];

      // Check day 1
      var day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings.length, 1);

      // Check day 2
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 16),
      );
      expect(day.meetings.length, 1);

      // Check day 3
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 17),
      );
      expect(day.meetings.length, 1);

      // Check day 4 (should be empty, COUNT=3)
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 18),
      );
      expect(day.meetings, isEmpty);
    });

    test('expands weekly recurring events', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0), // Monday
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Weekly Team Meeting',
          allDay: false,
          attendeeCount: 5,
          rrule: 'FREQ=WEEKLY;COUNT=2',
          uid: 'weekly-1',
        ),
      ];

      // Check first Monday
      var day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings.length, 1);

      // Check Tuesday (should be empty)
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 16),
      );
      expect(day.meetings, isEmpty);

      // Check next Monday
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 22),
      );
      expect(day.meetings.length, 1);
    });

    test('respects BYDAY in weekly recurrence', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0), // Monday
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'MWF Meeting',
          allDay: false,
          attendeeCount: 3,
          rrule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6',
          uid: 'mwf-1',
        ),
      ];

      // Monday
      var day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings.length, 1);

      // Tuesday (should be empty)
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 16),
      );
      expect(day.meetings, isEmpty);

      // Wednesday
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 17),
      );
      expect(day.meetings.length, 1);

      // Friday
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 19),
      );
      expect(day.meetings.length, 1);
    });

    test('respects UNTIL date', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Meeting until Feb',
          allDay: false,
          attendeeCount: 2,
          rrule: 'FREQ=DAILY;UNTIL=20240117T235959',
          uid: 'until-1',
        ),
      ];

      // Day 1 - should exist
      var day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings.length, 1);

      // Day 3 (last day)
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 17),
      );
      expect(day.meetings.length, 1);

      // Day 4 (after UNTIL)
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 18),
      );
      expect(day.meetings, isEmpty);
    });

    test('excludes EXDATE from recurrence', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Daily with exception',
          allDay: false,
          attendeeCount: 2,
          rrule: 'FREQ=DAILY;COUNT=5',
          uid: 'exdate-test',
          exdates: [DateTime(2024, 1, 17)], // Exclude Jan 17
        ),
      ];

      // Jan 15 - should exist
      var day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings.length, 1);

      // Jan 17 - excluded
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 17),
      );
      expect(day.meetings, isEmpty);

      // Jan 18 - should exist
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 18),
      );
      expect(day.meetings.length, 1);
    });

    test('respects INTERVAL in recurrence', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Every other day',
          allDay: false,
          attendeeCount: 2,
          rrule: 'FREQ=DAILY;INTERVAL=2;COUNT=3',
          uid: 'interval-1',
        ),
      ];

      // Day 1 (Jan 15)
      var day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings.length, 1);

      // Day 2 (Jan 16) - skipped
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 16),
      );
      expect(day.meetings, isEmpty);

      // Day 3 (Jan 17) - should exist
      clearIcsDayCache();
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 17),
      );
      expect(day.meetings.length, 1);
    });
  });

  group('setNonMeetingHints', () {
    test('updates hints and invalidates cache', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Custom Hint Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
      ];

      // Initially should be a meeting
      var day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings.length, 1);

      // Add custom hint
      setNonMeetingHints(['custom hint']);

      // Now should be filtered
      day = buildDayCalendarCached(
        allEvents: events,
        day: DateTime(2024, 1, 15),
      );
      expect(day.meetings, isEmpty);
    });

    test('getNonMeetingHints returns current hints', () {
      setNonMeetingHints(['test1', 'test2']);
      final hints = getNonMeetingHints();
      expect(hints, contains('test1'));
      expect(hints, contains('test2'));
    });
  });

  group('Range cache', () {
    test('prepareUserMeetingsRange caches data for range', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
      ];

      prepareUserMeetingsRange(
        allEvents: events,
        userEmail: 'test@example.com',
        from: DateTime(2024, 1, 15),
        to: DateTime(2024, 1, 20),
      );

      expect(
        userRangeCacheCoversDay(
          day: DateTime(2024, 1, 15),
          userEmail: 'test@example.com',
        ),
        true,
      );

      expect(
        userRangeCacheCoversDay(
          day: DateTime(2024, 1, 22), // Outside range
          userEmail: 'test@example.com',
        ),
        false,
      );
    });

    test('meetingsForUserOnDayFast returns cached meetings', () {
      final events = [
        IcsEvent(
          start: DateTime(2024, 1, 15, 10, 0),
          end: DateTime(2024, 1, 15, 11, 0),
          summary: 'Cached Meeting',
          allDay: false,
          attendeeCount: 2,
        ),
      ];

      prepareUserMeetingsRange(
        allEvents: events,
        userEmail: 'test@example.com',
        from: DateTime(2024, 1, 15),
        to: DateTime(2024, 1, 20),
      );

      final meetings = meetingsForUserOnDayFast(
        day: DateTime(2024, 1, 15),
        userEmail: 'test@example.com',
      );

      expect(meetings.length, 1);
      expect(meetings[0].summary, 'Cached Meeting');
    });
  });
}
