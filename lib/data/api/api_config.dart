/// Reads API keys baked in at build time via `--dart-define-from-file`
/// (see env.example.json at the repo root). Every caller checks the
/// matching `hasXKey` flag before touching the network, so the app runs
/// fine with zero keys configured — the phonetic/translation tiers just
/// stay off — and lighting a key up later needs no code change, only a
/// rebuild with the key present.
class ApiConfig {
  ApiConfig._();

  static const String anthropicApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
  static const String deeplApiKey = String.fromEnvironment('DEEPL_API_KEY');

  static bool get hasAnthropicKey => anthropicApiKey.isNotEmpty;
  static bool get hasDeepLKey => deeplApiKey.isNotEmpty;
}
