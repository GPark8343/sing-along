/// Reads API keys baked in at build time via `--dart-define-from-file`
/// (see env.example.json at the repo root). Every caller checks the
/// matching `hasXKey` flag before touching the network, so the app runs
/// fine with zero keys configured — the translation tier just stays off —
/// and lighting a key up later needs no code change, only a rebuild with
/// the key present. The phonetic (독음) tier no longer needs a key at all:
/// it runs on-device via Kuromoji, see JapaneseReadingClient.
class ApiConfig {
  ApiConfig._();

  static const String deeplApiKey = String.fromEnvironment('DEEPL_API_KEY');

  static bool get hasDeepLKey => deeplApiKey.isNotEmpty;
}
