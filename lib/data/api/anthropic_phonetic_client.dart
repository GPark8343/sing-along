import 'dart:convert';

import 'package:dio/dio.dart';

import 'api_config.dart';

/// Both Goo Lab (NTT Resonant) and Yahoo! JAPAN's furigana service turned
/// out to be region-locked in ways that blocked this project (the former
/// unreachable outright, the latter requiring a Japanese phone number to
/// register for a key) — Claude has no such restriction and can do the
/// kanji-reading-in-context resolution *and* the kana-to-Korean
/// transliteration in a single step, so this replaces that whole two-stage
/// pipeline (morphological analysis client + a hand-written kana->Hangul
/// table) with one model call.
class AnthropicPhoneticClient {
  AnthropicPhoneticClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.anthropic.com/v1',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: {
                'x-api-key': ApiConfig.anthropicApiKey,
                'anthropic-version': '2023-06-01',
                'content-type': 'application/json',
              },
            ));

  final Dio _dio;

  /// Returns the Korean phonetic reading (독음) for each input line, in the
  /// same order — or null if no key is configured, the call failed, or the
  /// response wasn't a JSON array with exactly one entry per input line
  /// (safer to drop the whole phonetic tier for this song than show one
  /// misaligned with the original lines).
  Future<List<String>?> readingsForLines(List<String> lines) async {
    if (!ApiConfig.hasAnthropicKey || lines.isEmpty) return null;
    try {
      final numbered = [for (var i = 0; i < lines.length; i++) '${i + 1}. ${lines[i]}'].join('\n');
      final response = await _dio.post<Map<String, dynamic>>('/messages', data: {
        'model': 'claude-haiku-4-5-20251001',
        'max_tokens': 2048,
        'messages': [
          {
            'role': 'user',
            'content': '다음은 일본어 노래 가사입니다. 각 줄을 한국어 독음(한자와 가나를 한글 발음으로 표기)으로 '
                '변환해서, 정확히 ${lines.length}개의 문자열로 이루어진 JSON 배열로만 응답하세요. '
                '다른 설명이나 markdown 코드블록 없이 JSON 배열 하나만 출력하세요.\n\n$numbered',
          },
        ],
      });
      final content = response.data?['content'] as List<dynamic>?;
      if (content == null || content.isEmpty) return null;
      final text = (content.first as Map<String, dynamic>)['text'] as String?;
      if (text == null) return null;
      final decoded = jsonDecode(_extractJsonArray(text));
      if (decoded is! List || decoded.length != lines.length) return null;
      return decoded.map((entry) => entry as String).toList();
    } on DioException {
      return null;
    } on FormatException {
      return null;
    }
  }

  String _extractJsonArray(String text) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end == -1 || end < start) return text;
    return text.substring(start, end + 1);
  }
}
