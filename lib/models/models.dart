// lib/models/models.dart  (ERGÄNZT CSV-KONFIG)
class SettingsModel {
  String meetingIssueKey;
  String fallbackIssueKey;

  // Jira credentials
  String jiraBaseUrl;
  String jiraEmail;
  String jiraApiToken;

  String timezone;

  // CSV-Konfiguration
  String csvDelimiter; // z. B. ";" oder ","
  bool csvHasHeader; // erste Zeile enthält Spaltennamen?
  String csvColDescription; // Spalte für "Beschreibung/Aktion" (optional)
  String csvColDate; // Spalte für Datum (yyyy-MM-dd)
  String csvColStart; // Spalte für Start (yyyy-MM-dd HH:mm:ss)
  String csvColEnd; // Spalte für Ende  (yyyy-MM-dd HH:mm:ss)
  String csvColDuration; // Spalte für Dauer (z. B. 7.50 oder 07:30) (optional)
  String csvColPauseTotal; // Spalte für Gesamtpausendauer an dem Tag
  String csvColPauseRanges; // Spalte für die einzelnen Pausen im Format ("10:00-10:15; 10:30-10:45")

  // GitLab
  String gitlabBaseUrl; // https://gitlab.example.com
  String gitlabToken; // PRIVATE-TOKEN
  String gitlabProjectIds; // Komma-/Leerzeichen-getrennt: "123, 456"
  String gitlabAuthorEmail; // optional: nur Commits dieser Mail
  int gitlabLookbackDays; // Lookback in Tagen, um „letztes Ticket“ vor dem Zeitraum zu finden

  SettingsModel({
    this.meetingIssueKey = '',
    this.fallbackIssueKey = '',
    this.jiraBaseUrl = '',
    this.jiraEmail = '',
    this.jiraApiToken = '',
    this.timezone = 'Europe/Vienna',
    // Defaults für Timetac-Export
    this.csvDelimiter = ';',
    this.csvHasHeader = true,
    this.csvColDescription = 'Kommentar',
    this.csvColDate = 'Datum',
    this.csvColStart = 'K',
    this.csvColEnd = 'G',
    this.csvColDuration = 'GIBA',
    this.csvColPauseTotal = 'P',
    this.csvColPauseRanges = 'Pausen',
    this.gitlabBaseUrl = '',
    this.gitlabToken = '',
    this.gitlabProjectIds = '',
    this.gitlabAuthorEmail = '',
    this.gitlabLookbackDays = 30,
  });

  Map<String, dynamic> toJson() => {
        'meetingIssueKey': meetingIssueKey,
        'fallbackIssueKey': fallbackIssueKey,
        'jiraBaseUrl': jiraBaseUrl,
        'jiraEmail': jiraEmail,
        'jiraApiToken': jiraApiToken,
        'timezone': timezone,
        'csvDelimiter': csvDelimiter,
        'csvHasHeader': csvHasHeader,
        'csvColDescription': csvColDescription,
        'csvColDate': csvColDate,
        'csvColStart': csvColStart,
        'csvColEnd': csvColEnd,
        'csvColDuration': csvColDuration,
        'csvColPauseTotal': csvColPauseTotal,
        'csvColPauseRanges': csvColPauseRanges,
        'gitlabBaseUrl': gitlabBaseUrl,
        'gitlabToken': gitlabToken,
        'gitlabProjectIds': gitlabProjectIds,
        'gitlabAuthorEmail': gitlabAuthorEmail,
        'gitlabLookbackDays': gitlabLookbackDays,
      };

  factory SettingsModel.fromJson(Map<String, dynamic> m) => SettingsModel(
        meetingIssueKey: (m['meetingIssueKey'] ?? '').toString(),
        fallbackIssueKey: (m['fallbackIssueKey'] ?? '').toString(),
        jiraBaseUrl: (m['jiraBaseUrl'] ?? '').toString(),
        jiraEmail: (m['jiraEmail'] ?? '').toString(),
        jiraApiToken: (m['jiraApiToken'] ?? '').toString(),
        timezone: (m['timezone'] ?? 'Europe/Vienna').toString(),
        csvDelimiter: (m['csvDelimiter'] ?? ';').toString(),
        csvHasHeader: (m['csvHasHeader'] ?? false) as bool,
        csvColDescription: (m['csvColDescription'] ?? '').toString(),
        csvColDate: (m['csvColDate'] ?? '').toString(),
        csvColStart: (m['csvColStart'] ?? '').toString(),
        csvColEnd: (m['csvColEnd'] ?? '').toString(),
        csvColDuration: (m['csvColDuration'] ?? '').toString(),
        csvColPauseTotal: (m['csvColPauseTotal'] ?? '').toString(),
        csvColPauseRanges: (m['csvColPauseRanges'] ?? '').toString(),
        gitlabBaseUrl: (m['gitlabBaseUrl'] ?? '').toString(),
        gitlabToken: (m['gitlabToken'] ?? '').toString(),
        gitlabProjectIds: (m['gitlabProjectIds'] ?? '').toString(),
        gitlabAuthorEmail: (m['gitlabAuthorEmail'] ?? '').toString(),
        gitlabLookbackDays: (m['gitlabLookbackDays'] ?? 30) is int
            ? m['gitlabLookbackDays'] as int
            : int.tryParse((m['gitlabLookbackDays'] ?? '30').toString()) ?? 30,
      );
}

// Einfache Range für Pausen (damit kein Zirkelimport zu WorkWindow entsteht)
class TimeRange {
  TimeRange(this.start, this.end);
  DateTime start;
  DateTime end;
  Duration get duration => end.difference(start);
}

class TimetacRow {
  final String description;
  final DateTime date; // day-only
  final DateTime? start; // optional
  final DateTime? end; // optional
  final Duration duration; // preferred from start/end
  final Duration pauseTotal;
  final List<TimeRange> pauses;

  TimetacRow({
    required this.description,
    required this.date,
    required this.start,
    required this.end,
    required this.duration,
    this.pauseTotal = Duration.zero,
    List<TimeRange>? pauses,
  }) : pauses = pauses ?? const [];
}

class DayTotals {
  final DateTime date;
  final Duration timetacTotal;
  final Duration meetingsTotal;
  final Duration leftover;

  DayTotals({
    required this.date,
    required this.timetacTotal,
    required this.meetingsTotal,
    required this.leftover,
  });
}
