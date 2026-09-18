import 'package:dio/dio.dart';

import 'api_config.dart';

/// DeepL's `text` parameter accepts an array and returns translations in
/// the same order/count — sending every lyric line in one request keeps
/// each translated line aligned with its original by index, avoiding the
/// fragile "translate the whole block, then re-split by line count" that
/// breaks whenever DeepL merges or reflows lines.
class DeepLClient {
  DeepLClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              // DeepL free-tier keys always end in ":fx" and only work
              // against the free API host — paid keys need the other one.
              baseUrl: ApiConfig.deeplApiKey.endsWith(':fx') ? 'https://api-free.deepl.com/v2' : 'https://api.deepl.com/v2',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: {'Authorization': 'DeepL-Auth-Key ${ApiConfig.deeplApiKey}'},
            ));

  final Dio _dio;

  /// Returns the Korean translation for each input line, in the same
  /// order — or null if the call failed, no key is configured, or the
  /// response didn't line up 1:1 with what was sent.
  Future<List<String>?> translateLines(List<String> lines) async {
    if (!ApiConfig.hasDeepLKey || lines.isEmpty) return null;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/translate',
        data: {'text': lines, 'target_lang': 'KO'},
      );
      final translations = response.data?['translations'] as List<dynamic>?;
      if (translations == null || translations.length != lines.length) return null;
      return translations.map((entry) => (entry as Map<String, dynamic>)['text'] as String).toList();
    } on DioException {
      return null;
    }
  }
}
