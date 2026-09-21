import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Translates lyric lines to Korean via ML Kit's on-device translation models — no network
/// call per translation, no API key, no usage-based cost at all, unlike the cloud APIs
/// (DeepL, Gemini) this replaced. Each [OnDeviceTranslator] is bound to one fixed source
/// language, so this holds one instance per source language this app actually needs
/// (Japanese and English) rather than a single general-purpose client; Spanish lines are left
/// untranslated for now — see LyricsRepository._buildResult for how lines are routed here.
class MlKitTranslationClient {
  MlKitTranslationClient()
      : _japaneseTranslator = OnDeviceTranslator(
          sourceLanguage: TranslateLanguage.japanese,
          targetLanguage: TranslateLanguage.korean,
        ),
        _englishTranslator = OnDeviceTranslator(
          sourceLanguage: TranslateLanguage.english,
          targetLanguage: TranslateLanguage.korean,
        ),
        _modelManager = OnDeviceTranslatorModelManager();

  final OnDeviceTranslator _japaneseTranslator;
  final OnDeviceTranslator _englishTranslator;
  final OnDeviceTranslatorModelManager _modelManager;
  final Set<String> _readyModels = {};

  /// Returns the Korean translation for each input Japanese line, in the same order — or null
  /// if the on-device model isn't available/downloadable, or the call otherwise failed.
  Future<List<String>?> translateJapaneseLines(List<String> lines) =>
      _translate(_japaneseTranslator, TranslateLanguage.japanese, lines);

  /// Same contract as [translateJapaneseLines], for English lines.
  Future<List<String>?> translateEnglishLines(List<String> lines) =>
      _translate(_englishTranslator, TranslateLanguage.english, lines);

  Future<List<String>?> _translate(
    OnDeviceTranslator translator,
    TranslateLanguage sourceLanguage,
    List<String> lines,
  ) async {
    if (lines.isEmpty) return null;
    if (!await _ensureModelDownloaded(sourceLanguage)) return null;
    try {
      // One at a time, not concurrently — this is on-device inference sharing the same
      // underlying model/thread, not an independent network request per line, so firing many
      // at once wouldn't actually parallelize the work the way concurrent HTTP calls did for
      // DeepL/Gemini; it would just queue behind itself.
      final results = <String>[];
      for (final line in lines) {
        results.add(await translator.translateText(line));
      }
      return results;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _ensureModelDownloaded(TranslateLanguage language) async {
    final code = language.bcpCode;
    if (_readyModels.contains(code)) return true;
    try {
      final alreadyDownloaded = await _modelManager.isModelDownloaded(code);
      // Not gated to Wi-Fi-only — each model is a one-time ~30MB download, and defaulting to
      // Wi-Fi-required would silently make translation just never work for anyone on mobile
      // data with no indication why.
      final ready = alreadyDownloaded || await _modelManager.downloadModel(code, isWifiRequired: false);
      if (ready) _readyModels.add(code);
      return ready;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _japaneseTranslator.close();
    _englishTranslator.close();
  }
}
