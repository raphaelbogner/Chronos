// lib/services/ics_parser.dart
import 'dart:convert';

class IcsEvent {
  IcsEvent({
    required this.start,
    required this.end,
    required this.summary,
    required this.allDay,
    this.status,
    this.transp,
    this.busyStatus,
    this.uid,
    this.rrule,
    this.categories,
    this.description,
    this.attendeeCount = 0,
    List<DateTime>? exdates,
  }) : exdates = exdates ?? [];

  DateTime start;
  DateTime end;
  String summary;
  bool allDay;

  String? status;
  String? transp;
  String? busyStatus;
  String? uid;
  String? rrule;
  String? categories;
  String? description;
  int attendeeCount;

  List<DateTime> exdates;

  Duration get duration => end.difference(start);
}

class IcsParseResult {
  IcsParseResult(this.events);
  final List<IcsEvent> events;
}

DateTime _parseIcsDateTime(String v) {
  if (v.endsWith('Z')) return DateTime.parse(v).toLocal();
  return DateTime.parse(v);
}

bool _isCancelled(IcsEvent e) {
  final s = (e.status ?? '').toUpperCase();
  if (s.contains('CANCELLED')) return true;
  final t = (e.summary).toLowerCase();
  return t.contains('abgesagt') || t.contains('canceled') || t.contains('cancelled');
}

bool _isAllDayDayOff(IcsEvent e) {
  if (!e.allDay) return false;
  final t = e.summary.toLowerCase();
  if (t.contains('homeoffice') || t.contains('an anderem ort')) return false;
  if (t.contains('urlaub') || t.contains('feiertag') || t.contains('krank')) return true;
  final busy = (e.busyStatus ?? '').toUpperCase();
  if (busy == 'OOF') return true;
  if (t.contains('abwesend')) return true;
  return false;
}

bool _crossesMidnight(IcsEvent e) => e.start.day != e.end.day || e.start.isAfter(e.end);

bool _tooLong(IcsEvent e) => e.duration > const Duration(hours: 10);

List<IcsEvent> _expandRecurringForWindow(
  List<IcsEvent> recurring,
  DateTime from,
  DateTime to,
) {
  final out = <IcsEvent>[];
  for (final e in recurring) {
    final rule = e.rrule;
    if (rule == null || rule.trim().isEmpty) continue;

    final parts = <String, String>{};
    for (final p in rule.split(';')) {
      final i = p.indexOf('=');
      if (i > 0) parts[p.substring(0, i).toUpperCase()] = p.substring(i + 1);
    }

    final freq = (parts['FREQ'] ?? '').toUpperCase();
    if (freq != 'DAILY' && freq != 'WEEKLY') {
      if (!(e.end.isBefore(from) || e.start.isAfter(to))) out.add(e);
      continue;
    }

    final until = parts['UNTIL'] != null ? _parseIcsDateTime(parts['UNTIL']!) : null;
    final count = parts['COUNT'] != null ? int.tryParse(parts['COUNT']!) : null;
    final byday = parts['BYDAY']?.split(',').map((s) => s.toUpperCase()).toList() ?? const <String>[];

    bool matchesByDay(DateTime dt) {
      if (byday.isEmpty) return true;
      const map = {
        DateTime.monday: 'MO',
        DateTime.tuesday: 'TU',
        DateTime.wednesday: 'WE',
        DateTime.thursday: 'TH',
        DateTime.friday: 'FR',
        DateTime.saturday: 'SA',
        DateTime.sunday: 'SU',
      };
      return byday.contains(map[dt.weekday]);
    }

    const step = Duration(days: 1);
    DateTime instStart = e.start;
    DateTime instEnd = e.end;
    int emitted = 0;
    DateTime hardEnd = to;
    if (until != null && until.isBefore(hardEnd)) hardEnd = until;

    while (instEnd.isBefore(from)) {
      instStart = instStart.add(step);
      instEnd = instEnd.add(step);
      if (freq == 'WEEKLY' && !matchesByDay(instStart)) continue;
      if (count != null && emitted >= count) break;
    }

    while (!instStart.isAfter(hardEnd)) {
      if ((freq != 'WEEKLY') || matchesByDay(instStart)) {
        final isExcluded =
            e.exdates.any((ex) => ex.year == instStart.year && ex.month == instStart.month && ex.day == instStart.day);
        if (!isExcluded) {
          if (!(instEnd.isBefore(from) || instStart.isAfter(to))) {
            out.add(IcsEvent(
              start: instStart,
              end: instEnd,
              summary: e.summary,
              allDay: e.allDay,
              status: e.status,
              transp: e.transp,
              busyStatus: e.busyStatus,
              uid: e.uid,
              rrule: e.rrule,
              categories: e.categories,
              description: e.description,
              attendeeCount: e.attendeeCount,
            ));
            emitted++;
            if (count != null && emitted >= count) break;
          }
        }
      }
      instStart = instStart.add(step);
      instEnd = instEnd.add(step);
    }
  }
  return out;
}

IcsParseResult parseIcs(String content) {
  final lines = const LineSplitter().convert(content).fold<List<String>>(<String>[], (acc, line) {
    if (line.startsWith(' ') || line.startsWith('\t')) {
      if (acc.isNotEmpty) acc[acc.length - 1] = acc.last + line.substring(1);
    } else {
      acc.add(line);
    }
    return acc;
  });

  final events = <IcsEvent>[];
  Map<String, String> cur = {};
  List<DateTime> exdates = [];
  bool inEvent = false;
  int attendeeCount = 0;

  DateTime? valueDateToStart(String v) {
    if (v.length >= 8) {
      final y = int.parse(v.substring(0, 4));
      final m = int.parse(v.substring(4, 6));
      final d = int.parse(v.substring(6, 8));
      return DateTime(y, m, d);
    }
    return null;
  }

  DateTime? valueDateToEnd(String v) {
    final s = valueDateToStart(v);
    if (s == null) return null;
    return s.add(const Duration(days: 1));
  }

  for (final raw in lines) {
    if (raw == 'BEGIN:VEVENT') {
      inEvent = true;
      cur = {};
      exdates = [];
      attendeeCount = 0;
      continue;
    }
    if (raw == 'END:VEVENT') {
      inEvent = false;

      final sum = cur['SUMMARY'] ?? cur['SUMMARY;LANGUAGE=de'] ?? '';
      final status = cur['STATUS'];
      final transp = cur['TRANSP'];
      final busy = cur['X-MICROSOFT-CDO-BUSYSTATUS'] ?? cur['BUSYSTATUS'];
      final uid = cur['UID'];
      final rrule = cur['RRULE'];
      final categories = cur['CATEGORIES'];
      final description = cur['DESCRIPTION'];

      DateTime? dtStart;
      DateTime? dtEnd;
      bool allDay = false;

      if (cur.containsKey('DTSTART')) {
        dtStart = _parseIcsDateTime(cur['DTSTART']!);
      } else if (cur.keys.any((k) => k.startsWith('DTSTART;VALUE=DATE'))) {
        final k = cur.keys.firstWhere((k) => k.startsWith('DTSTART;VALUE=DATE'));
        final v = cur[k]!;
        dtStart = valueDateToStart(v);
        allDay = true;
      } else if (cur.keys.any((k) => k.startsWith('DTSTART;TZID'))) {
        dtStart = _parseIcsDateTime(cur[cur.keys.firstWhere((k) => k.startsWith('DTSTART;TZID'))]!);
      }

      if (cur.containsKey('DTEND')) {
        dtEnd = _parseIcsDateTime(cur['DTEND']!);
      } else if (cur.keys.any((k) => k.startsWith('DTEND;VALUE=DATE'))) {
        final k = cur.keys.firstWhere((k) => k.startsWith('DTEND;VALUE=DATE'));
        final v = cur[k]!;
        dtEnd = valueDateToEnd(v);
        allDay = true;
      } else if (cur.keys.any((k) => k.startsWith('DTEND;TZID'))) {
        dtEnd = _parseIcsDateTime(cur[cur.keys.firstWhere((k) => k.startsWith('DTEND;TZID'))]!);
      }

      if (dtStart != null && dtEnd != null) {
        events.add(IcsEvent(
          start: dtStart,
          end: dtEnd,
          summary: sum,
          allDay: allDay,
          status: status,
          transp: transp,
          busyStatus: busy,
          uid: uid,
          rrule: rrule,
          categories: categories,
          description: description,
          attendeeCount: attendeeCount,
          exdates: exdates,
        ));
      }
      continue;
    }

    if (!inEvent) continue;

    if (raw.startsWith('EXDATE')) {
      final idx = raw.indexOf(':');
      if (idx > 0) {
        final v = raw.substring(idx + 1);
        for (final part in v.split(',')) {
          final s = part.trim();
          if (s.length == 8) {
            final y = int.parse(s.substring(0, 4));
            final m = int.parse(s.substring(4, 6));
            final d = int.parse(s.substring(6, 8));
            exdates.add(DateTime(y, m, d));
          } else {
            exdates.add(_parseIcsDateTime(s));
          }
        }
      }
      continue;
    }

    if (raw.startsWith('ATTENDEE')) {
      attendeeCount++;
      continue;
    }

    final i = raw.indexOf(':');
    if (i > 0) {
      final k = raw.substring(0, i);
      final v = raw.substring(i + 1);
      cur.putIfAbsent(k, () => v);
      if (k.startsWith('SUMMARY;')) cur.putIfAbsent('SUMMARY', () => v);
    }
  }

  return IcsParseResult(events);
}

class DayCalendar {
  DayCalendar({required this.meetings, required this.dayOff});
  final List<IcsEvent> meetings;
  final bool dayOff;
}

class _IcsDayCache {
  final Map<int, DayCalendar> _cache = <int, DayCalendar>{};
  void clear() => _cache.clear();

  DayCalendar getOrCompute(List<IcsEvent> allEvents, DateTime day) {
    final key = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final cached = _cache[key];
    if (cached != null) return cached;

    final simple = <IcsEvent>[];
    final recurring = <IcsEvent>[];
    for (final e in allEvents) {
      if (e.rrule == null || e.rrule!.trim().isEmpty) {
        simple.add(e);
      } else {
        recurring.add(e);
      }
    }

    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));

    final candidates = <IcsEvent>[
      ...simple.where((e) => !(e.end.isBefore(from) || e.start.isAfter(to))),
      ..._expandRecurringForWindow(recurring, from, to),
    ];

    final hasDayOff = candidates.any(_isAllDayDayOff);

    final meetings = candidates.where((e) {
      if (_isCancelled(e)) return false;
      if (e.allDay) return false;
      if (_crossesMidnight(e)) return false;
      if (_tooLong(e)) return false;

      final transpUpper = (e.transp ?? '').toUpperCase();
      final busyUpper = (e.busyStatus ?? '').toUpperCase();
      if (transpUpper == 'TRANSPARENT') return false;
      if (busyUpper == 'FREE' || busyUpper == 'WORKINGELSEWHERE' || busyUpper == 'OOF' || busyUpper == 'TENTATIVE') {
        return false;
      }

      // Harte Regel: nur Events mit Teilnehmern zählen (verhindert stille "Anwesenheits"-Serien)
      if (e.attendeeCount == 0) return false;

      final title = (e.summary).trim().toLowerCase();
      const nonMeetingHints = <String>[
        'homeoffice',
        'an anderem ort tätig',
        'im büro',
        'im office',
        'office',
        'büro',
        'arbeitsort',
        'arbeitsplatz',
        'standort',
        'working elsewhere',
        'focus',
        'focus time',
        'fokuszeit',
        'reise',
        'anreise',
        'commute',
        'fahrt',
        'fahrtzeit',
        'travel',
        'anwesenheit',
        'präsenz',
      ];
      if (title.isEmpty || nonMeetingHints.any((k) => title.contains(k))) return false;

      final s = e.start.isBefore(from) ? from : e.start;
      final end = e.end.isAfter(to) ? to : e.end;
      return end.isAfter(s);
    }).map((e) {
      final s = e.start.isBefore(from) ? from : e.start;
      final end = e.end.isAfter(to) ? to : e.end;
      return IcsEvent(
        start: s,
        end: end,
        summary: e.summary,
        allDay: false,
        status: e.status,
        transp: e.transp,
        busyStatus: e.busyStatus,
        uid: e.uid,
        categories: e.categories,
        description: e.description,
        attendeeCount: e.attendeeCount,
      );
    }).toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    // Merge with minimum overlap (prevents short overlaps gluing multiple blocks)
    const Duration minMergeOverlap = Duration(minutes: 10);
    final merged = <IcsEvent>[];
    for (final m in meetings) {
      if (merged.isEmpty) {
        merged.add(m);
      } else {
        final last = merged.last;
        final overlapStart = m.start.isAfter(last.start) ? m.start : last.start;
        final overlapEnd = m.end.isBefore(last.end) ? m.end : last.end;
        final overlap = overlapEnd.isAfter(overlapStart) ? overlapEnd.difference(overlapStart) : Duration.zero;
        final overlapsEnough = overlap >= minMergeOverlap;
        if (overlapsEnough) {
          final newEnd = m.end.isAfter(last.end) ? m.end : last.end;
          merged[merged.length - 1] = IcsEvent(
            start: last.start,
            end: newEnd,
            summary: '${last.summary} + ${m.summary}',
            allDay: false,
            status: last.status,
            transp: last.transp,
            busyStatus: last.busyStatus,
            uid: last.uid,
            categories: last.categories,
            description: last.description,
            attendeeCount: last.attendeeCount,
          );
        } else {
          merged.add(m);
        }
      }
    }

    final dc = DayCalendar(meetings: merged, dayOff: hasDayOff);
    _cache[key] = dc;
    return dc;
  }
}

final _IcsDayCache _dayCache = _IcsDayCache();
void clearIcsDayCache() => _dayCache.clear();

DayCalendar buildDayCalendarCached({required List<IcsEvent> allEvents, required DateTime day}) =>
    _dayCache.getOrCompute(allEvents, day);

DayCalendar buildDayCalendar({required List<IcsEvent> allEvents, required DateTime day}) =>
    buildDayCalendarCached(allEvents: allEvents, day: day);
