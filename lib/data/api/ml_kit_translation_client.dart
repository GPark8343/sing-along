import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Translates lyric lines to Korean via ML Kit's on-device translation models — no network
/// call per translation, no API key, no usage-based cost at all, unlike the cloud APIs
/// (DeepL, Gemini) this replaced. Each [OnDeviceTranslator] is bound to one fixed source
/// language, so this holds one instance per source language this app actually needs
/// (Japanese, English, Spanish, German) rather than a single general-purpose client — see
/// LyricsRepository._buildResult for how lines are routed here.
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
        _spanishTranslator = OnDeviceTranslator(
          sourceLanguage: TranslateLanguage.spanish,
          targetLanguage: TranslateLanguage.korean,
        ),
        _germanTranslator = OnDeviceTranslator(
          sourceLanguage: TranslateLanguage.german,
          targetLanguage: TranslateLanguage.korean,
        ),
        _modelManager = OnDeviceTranslatorModelManager(),
        // 0.5 is ML Kit's own documented default — low enough to still classify a short lyric
        // line (a whole confidence model has less to go on than a full paragraph) without
        // dropping to "und" (undetermined) so often that German lines just fall through to
        // the English translator by default anyway.
        _languageIdentifier = LanguageIdentifier(confidenceThreshold: 0.5);

  final OnDeviceTranslator _japaneseTranslator;
  final OnDeviceTranslator _englishTranslator;
  final OnDeviceTranslator _spanishTranslator;
  final OnDeviceTranslator _germanTranslator;
  final OnDeviceTranslatorModelManager _modelManager;
  final LanguageIdentifier _languageIdentifier;
  final Set<String> _readyModels = {};

  /// Returns the Korean translation for each input Japanese line, in the same order — or null
  /// if the on-device model isn't available/downloadable, or the call otherwise failed.
  Future<List<String>?> translateJapaneseLines(List<String> lines) =>
      _translate(_japaneseTranslator, TranslateLanguage.japanese, lines);

  /// Same contract as [translateJapaneseLines], for English lines.
  Future<List<String>?> translateEnglishLines(List<String> lines) =>
      _translate(_englishTranslator, TranslateLanguage.english, lines);

  /// Same contract as [translateJapaneseLines], for Spanish lines.
  Future<List<String>?> translateSpanishLines(List<String> lines) =>
      _translate(_spanishTranslator, TranslateLanguage.spanish, lines);

  /// Same contract as [translateJapaneseLines], for German lines.
  Future<List<String>?> translateGermanLines(List<String> lines) =>
      _translate(_germanTranslator, TranslateLanguage.german, lines);

  /// Splits `indices` — lines already known to be neither Japanese nor Spanish (those have
  /// their own dedicated detectors, see LyricsRepository._buildResult) — into German vs
  /// everything else, using ML Kit's own on-device language identifier per line rather than a
  /// hand-written detector like JapaneseDetector/SpanishDetector: that approach stopped
  /// scaling the moment a *second* non-Japanese language (German) needed distinguishing from
  /// English, and a general classifier is the only thing that keeps working as more languages
  /// get added later without a new hand-rolled detector each time. Lines the identifier can't
  /// confidently place ("und", or anything that isn't German) default to the English bucket,
  /// same as before this existed.
  Future<({List<int> german, List<int> english})> classifyGermanVsEnglish(
    List<int> indices,
    List<String> originalTexts,
  ) async {
    if (indices.isEmpty) return (german: <int>[], english: <int>[]);
    List<String> languageTags;
    try {
      languageTags = await Future.wait([
        for (final i in indices) _languageIdentifier.identifyLanguage(originalTexts[i]),
      ]);
    } catch (_) {
      // Identification itself failed — fall back to treating everything as English rather
      // than losing the translation tier for this whole bucket over a classifier error.
      return (german: <int>[], english: indices);
    }
    final german = <int>[];
    final english = <int>[];
    for (var k = 0; k < indices.length; k++) {
      (languageTags[k] == 'de' ? german : english).add(indices[k]);
    }
    return (german: german, english: english);
  }

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
    _spanishTranslator.close();
    _germanTranslator.close();
    _languageIdentifier.close();
  }
}
