// lib/services/jira_worklog_api.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

class JiraResponse {
  final bool ok;
  final int status;
  final String? body;
  JiraResponse(this.ok, this.status, this.body);
}

class JiraWorklogApi {
  final String baseUrl;
  final String email;
  final String apiToken;
  JiraWorklogApi({required this.baseUrl, required this.email, required this.apiToken});

  Map<String, String> get _headers => {
        'Authorization': 'Basic ${base64Encode(utf8.encode('$email:$apiToken'))}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  Future<JiraResponse> createWorklog({
    required String issueKeyOrId,
    required DateTime started,
    required int timeSpentSeconds,
    String? comment,
  }) async {
    final payload = <String, dynamic>{
      'started': started.toUtc().toIso8601String(),
      'timeSpentSeconds': timeSpentSeconds,
      if (comment != null) 'comment': comment,
    };
    final url = Uri.parse('$baseUrl/rest/api/3/issue/$issueKeyOrId/worklog');
    final res = await http.post(url, headers: _headers, body: jsonEncode(payload));
    return JiraResponse(res.statusCode >= 200 && res.statusCode < 300, res.statusCode, res.body);
  }
}
