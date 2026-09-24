import 'package:dio/dio.dart';

/// Translates lyric lines to Korean via DeepL, when the user has supplied their own API key
/// (see SettingsPage) — an opt-in, higher-quality alternative to the on-device ML Kit tier,
/// which routes every non-English source through an internal English pivot. The key is the
/// user's own, entered at runtime and never baked into the build, so unlike the old build-time
/// `ApiConfig.deeplApiKey` this takes it as a parameter on every call rather than reading a
/// compile-time constant.
class DeepLClient {
  DeepLClient({this.dio});

  final Dio? dio;

  /// Returns the Korean translation for each input line, in the same order — or null if the
  /// call failed, the key is invalid, or the response didn't line up 1:1 with what was sent.
  Future<List<String>?> translateLines(List<String> lines, String apiKey) async {
    if (apiKey.isEmpty || lines.isEmpty) return null;
    final client = dio ??
        Dio(BaseOptions(
          // DeepL free-tier keys always end in ":fx" and only work against the free API host —
          // paid keys need the other one.
          baseUrl: apiKey.endsWith(':fx') ? 'https://api-free.deepl.com/v2' : 'https://api.deepl.com/v2',
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          headers: {'Authorization': 'DeepL-Auth-Key $apiKey'},
        ));
    try {
      final response = await client.post<Map<String, dynamic>>(
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

  /// A cheap, near-instant call used only to validate a key before saving it (see
  /// SettingsPage's "연결 테스트" button) — DeepL's own usage endpoint, which every valid key
  /// can call regardless of remaining quota, so this tells "key is wrong/revoked" apart from
  /// "key is fine but quota happens to be exhausted right now".
  Future<bool> isKeyValid(String apiKey) async {
    if (apiKey.isEmpty) return false;
    final dio = Dio(BaseOptions(
      baseUrl: apiKey.endsWith(':fx') ? 'https://api-free.deepl.com/v2' : 'https://api.deepl.com/v2',
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'Authorization': 'DeepL-Auth-Key $apiKey'},
    ));
    try {
      final response = await dio.get('/usage');
      return response.statusCode == 200;
    } on DioException {
      return false;
    }
  }
}
