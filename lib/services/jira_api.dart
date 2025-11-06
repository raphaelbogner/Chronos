// lib/services/jira_api.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

class JiraApi {
  final String baseUrl;
  final String email;
  final String apiToken;
  JiraApi({required this.baseUrl, required this.email, required this.apiToken});

  Map<String, String> get _headers => {
        'Authorization': 'Basic ${base64Encode(utf8.encode('$email:$apiToken'))}',
        'Accept': 'application/json',
      };

  Future<String?> resolveIssueId(String issueKey) async {
    final url = Uri.parse('$baseUrl/rest/api/3/issue/$issueKey?fields=id');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final m = jsonDecode(res.body) as Map<String, dynamic>;
      return (m['id'] ?? '').toString();
    }
    return null;
  }
}
