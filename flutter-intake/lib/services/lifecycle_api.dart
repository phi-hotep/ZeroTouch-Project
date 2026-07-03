import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/lifecycle_request.dart';

/// Normalized result of a submission, independent of the transport.
class LifecycleResult {
  const LifecycleResult({
    required this.ok,
    required this.message,
    this.scheduled = false,
    this.raw,
  });

  final bool ok;
  final String message;
  final bool scheduled; // Future-dated Leaver -> scheduled, not executed
  final Map<String, dynamic>? raw;
}

/// Azure Function client. The URL and key are injected at build time via
/// --dart-define, never committed to the code.
class LifecycleApi {
  LifecycleApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _baseUrl = String.fromEnvironment('FUNCTION_URL');
  static const String _functionKey = String.fromEnvironment('FUNCTION_KEY');

  Future<LifecycleResult> submit(LifecycleRequest request) async {
    if (_baseUrl.isEmpty) {
      throw StateError(
        'FUNCTION_URL is not set. Launch with '
        '--dart-define=FUNCTION_URL=https://....azurewebsites.net/api/LifecycleHttp',
      );
    }

    final http.Response res;
    try {
      res = await _client.post(
        Uri.parse(_baseUrl),
        headers: {
          'Content-Type': 'application/json',
          if (_functionKey.isNotEmpty) 'x-functions-key': _functionKey,
        },
        body: jsonEncode(request.toJson()),
      );
    } catch (e) {
      return LifecycleResult(
        ok: false,
        message: 'Network error: $e',
      );
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      body = {'ok': false, 'error': 'Unreadable response (HTTP ${res.statusCode}).'};
    }

    final ok = body['ok'] == true;
    final scheduled = body['scheduled'] == true;
    return LifecycleResult(
      ok: ok,
      scheduled: scheduled,
      message: ok
          ? (body['message'] as String? ?? 'Operation successful.')
          : (body['error'] as String? ?? 'Error (HTTP ${res.statusCode}).'),
      raw: body,
    );
  }
}
