import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../core/text/japanese_detector.dart';
import '../../core/text/lrc_parser.dart';
import '../../core/text/spanish_detector.dart';
import '../../core/text/spanish_hangul.dart';
import '../../core/text/title_normalizer.dart';
import '../api/deepl_client.dart';
import '../api/lrclib_client.dart';
import '../api/ml_kit_translation_client.dart';
import '../hive/models/cached_lyric_line.dart';
import '../hive/models/cached_lyrics_entry.dart';
import '../native/japanese_reading_bridge.dart';
import '../secure/translation_key_storage.dart';

/// One lyric line with whichever tiers were actually available. [phonetic]
/// is only ever set for Japanese songs (computed on-device, no key needed);
/// [translation] is set for Japanese and English lines (on-device via ML
/// Kit) — Spanish lines get neither for now, and the overlay just omits a
/// tier that's null rather than showing a placeholder for it.
class LyricsLine {
  final int? timestampMs;
  final String original;
  final String? phonetic;
  final String? translation;

  const LyricsLine({
    required this.timestampMs,
    required this.original,
    this.phonetic,
    this.translation,
  });
}

class LyricsResult {
  final bool found;
  final List<LyricsLine> lines;
  final bool fromCache;
  // True only for lines the user typed/pasted in by hand — the overlay treats these
  // differently (it can't offer a paste UI itself, so it points the user at the full-screen
  // page instead of trying to render them).
  final bool isUserPasted;
  // The manual sync correction remembered from the last time this song was played, or 0 for
  // a song that's never had one set (including a brand new fetch) — see CachedLyricsEntry.
  final int syncOffsetMs;

  const LyricsResult({
    required this.found,
    required this.lines,
    this.fromCache = false,
    this.isUserPasted = false,
    this.syncOffsetMs = 0,
  });

  static const notFound = LyricsResult(found: false, lines: []);
}

/// Single entry point for turning "now playing" into lyrics: a Hive
/// cache-check first (an instant, network-free hit for any song played
/// before — including one that turned out to have no lyrics, so a
/// not-found song doesn't get re-queried every time it plays), then on a
/// miss, LRCLIB for the original text with an on-device Japanese reading
/// (독음) and on-device translation layered on top — each best-effort and
/// independently optional, never blocking the other or the original
/// lyrics themselves.
class LyricsRepository {
  LyricsRepository({
    required this._cacheBox,
    LrclibClient? lrclibClient,
    JapaneseReadingClient? phoneticClient,
    MlKitTranslationClient? translationClient,
    DeepLClient? deepLClient,
  }) : _lrclibClient = lrclibClient ?? LrclibClient(),
       _phoneticClient = phoneticClient ?? JapaneseReadingClient(),
       _translationClient = translationClient ?? MlKitTranslationClient(),
       _deepLClient = deepLClient ?? DeepLClient();

  final Box<CachedLyricsEntry> _cacheBox;
  final LrclibClient _lrclibClient;
  final JapaneseReadingClient _phoneticClient;
  final MlKitTranslationClient _translationClient;
  final DeepLClient _deepLClient;

  Future<LyricsResult> getLyrics({
    required String title,
    required String artist,
    int? durationSeconds,
  }) async {
    final key = TitleNormalizer.cacheKey(title, artist);
    final cached = _cacheBox.get(key);
    if (cached != null) return _fromCache(cached);

    final result = await _fetchFresh(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );
    await _cacheBox.put(key, _toCache(result));
    return result;
  }

  /// A synchronous, network-free lookup by the same cache key getLyrics() would compute
  /// itself — for a recent-songs list that already knows the exact key it wants (rather than
  /// re-deriving it from a possibly-different title/artist spelling), and shouldn't trigger a
  /// live LRCLIB fetch for a song that isn't actually playing. Null if nothing's cached there.
  LyricsResult? getCachedByKey(String cacheKey) {
    final cached = _cacheBox.get(cacheKey);
    return cached == null ? null : _fromCache(cached);
  }

  /// Re-runs the API lookup and overwrites whatever is currently cached for this song — used
  /// to undo a paste-in that turns out to have been a mistake (a typo, or the user pasting the
  /// wrong song's lyrics by accident), going back to LRCLIB's own answer instead of the
  /// user-entered one.
  Future<LyricsResult> refetchFromApi({
    required String title,
    required String artist,
    int? durationSeconds,
  }) async {
    final key = TitleNormalizer.cacheKey(title, artist);
    final result = await _fetchFresh(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );
    await _cacheBox.put(key, _toCache(result));
    return result;
  }

  /// Saves lyrics the user typed/corrected themselves, one line at a time (original/독음/번역
  /// kept together per line rather than as three parallel blocks of text) — either a fresh
  /// paste-in (LRCLIB matched the wrong song, or didn't have this one at all) or a correction
  /// of a few lines in an already-synced song. Skips the phonetic/translation *pipeline* (no
  /// on-device Kuromoji/ML Kit calls) since the user is providing that text directly.
  /// Each [LyricsLine.timestampMs] is trusted as given rather than forced to null — the
  /// whole-song correction layout preserves a synced song's original per-line timestamps when
  /// it builds [lines], while the paste-in layout never has any to begin with, so this doesn't
  /// need to know which case it's in: if *any* line still carries a real timestamp, this was a
  /// correction (kept synced, [isUserPasted] carried over from whatever's already cached rather
  /// than forced true), otherwise it's a genuine paste-in. A line with nothing typed for its
  /// original text is dropped; if that leaves nothing at all, the song is saved back to
  /// "no lyrics" rather than an empty entry.
  Future<LyricsResult> savePastedLyrics({
    required String title,
    required String artist,
    required List<LyricsLine> lines,
  }) async {
    final trimmedLines = [
      for (final line in lines)
        if (line.original.trim().isNotEmpty)
          LyricsLine(
            timestampMs: line.timestampMs,
            original: line.original.trim(),
            phonetic: _nonEmpty(line.phonetic),
            translation: _nonEmpty(line.translation),
          ),
    ];
    if (trimmedLines.isEmpty) return LyricsResult.notFound;
    final key = TitleNormalizer.cacheKey(title, artist);
    final preservesSync = trimmedLines.any((line) => line.timestampMs != null);
    final existing = preservesSync ? _cacheBox.get(key) : null;
    final result = LyricsResult(
      found: true,
      isUserPasted: preservesSync ? (existing?.isUserPasted ?? false) : true,
      syncOffsetMs: existing?.syncOffsetMs ?? 0,
      lines: trimmedLines,
    );
    await _cacheBox.put(key, _toCache(result));
    return result;
  }

  Future<LyricsResult> _fetchFresh({
    required String title,
    required String artist,
    int? durationSeconds,
  }) async {
    final artistName = TitleNormalizer.primaryArtist(artist);
    final isLive = TitleNormalizer.isLiveTitle(title);
    final featuredArtist = TitleNormalizer.featuredArtist(title, artist);

    LrclibLyrics? lrclib;
    var forceUnsynced = false;

    if (isLive) {
      // Try the literal, un-stripped title first — on the rare chance LRCLIB has a
      // dedicated submission specifically for this live performance, correctly timed to it,
      // it's worth a look before falling back to the studio recording.
      lrclib = await _lrclibClient.fetchLyrics(
        trackName: title,
        artistName: artistName,
        durationSeconds: durationSeconds,
        featuredArtist: featuredArtist,
      );
    }

    if (lrclib == null || !lrclib.hasLyrics) {
      lrclib = await _lrclibClient.fetchLyrics(
        trackName: TitleNormalizer.normalizeTitle(title),
        artistName: artistName,
        durationSeconds: durationSeconds,
        featuredArtist: featuredArtist,
      );
      // Whatever came back here is, at best, the studio recording's timing — a live
      // performance's actual pacing (extended intros, ad-libs, crowd noise, tempo drift)
      // never matches that, so this has to be shown unsynced (manual read-along) rather than
      // auto-scrolling to a beat that isn't the one actually playing.
      if (isLive) forceUnsynced = true;
    }

    if (lrclib == null || !lrclib.hasLyrics) {
      // No confident match for this exact recording at all — one last, much looser attempt
      // at a differently-arranged version of the same song (an orchestral/acoustic/live
      // arrangement LRCLIB has under its own distinct title) before giving up entirely. Its
      // timing belongs to that other arrangement, never this one, so it's always unsynced.
      final loose = await _lrclibClient.fetchLooseLyrics(
        trackName: TitleNormalizer.normalizeTitle(title),
        artistName: artistName,
      );
      if (loose != null && loose.hasLyrics) {
        lrclib = loose;
        forceUnsynced = true;
      }
    }

    if (lrclib == null || !lrclib.hasLyrics) return LyricsResult.notFound;

    final parsedLines = LrcParser.parse(
      lrclib.plainLyrics,
      lrclib.syncedLyrics,
    );
    if (parsedLines.isEmpty) return LyricsResult.notFound;

    return _buildResult(
      parsedLines.map((line) => line.text).toList(),
      forceUnsynced
          ? List<int?>.filled(parsedLines.length, null)
          : parsedLines.map((line) => line.timestampMs).toList(),
    );
  }

  // Shared by both a fresh LRCLIB fetch and a user-pasted paste-in: runs the on-device
  // phonetic reading (Japanese via Kuromoji, Spanish via rule-based transliteration) + on-
  // device translation pipeline over whatever original-language lines it's handed, whether
  // they came with LRC timestamps or not.
  Future<LyricsResult> _buildResult(
    List<String> originalTexts,
    List<int?> timestamps,
  ) async {
    // Classified one line at a time, not once for the whole song — a song can freely mix
    // Japanese/Spanish/English/other lines, and each only gets the phonetic tier that's
    // actually right for its own language (an English line gets none at all, the same way a
    // Korean reader doesn't need a 독음 for text they can already read as-is). Judging the
    // whole song as a single language was what previously let a handful of Spanish lines drag
    // an otherwise-English song's *entire* lyrics through the Spanish phonetic pipeline.
    final japaneseIndices = <int>[];
    final spanishIndices = <int>[];
    // Lines too short to independently tell apart from English — most commonly a repeated
    // one-word chorus/hook line (a whole song built around "Despacito" on its own has no
    // second word for isSpanish()'s 2-hit stopword bar to ever reach) — collected separately
    // and only promoted to Spanish below if the rest of the song already leans confidently
    // Spanish, rather than trusted on their own.
    final maybeSpanishIndices = <int>[];
    for (var i = 0; i < originalTexts.length; i++) {
      final text = originalTexts[i];
      if (JapaneseDetector.isJapanese(text)) {
        japaneseIndices.add(i);
      } else if (SpanishDetector.isSpanish(text)) {
        spanishIndices.add(i);
      } else if (SpanishDetector.isMaybeSpanish(text)) {
        maybeSpanishIndices.add(i);
      }
    }
    final confidentNonJapaneseCount =
        originalTexts.length - japaneseIndices.length;
    if (confidentNonJapaneseCount > 0 &&
        spanishIndices.length / confidentNonJapaneseCount >= 0.3) {
      spanishIndices.addAll(maybeSpanishIndices);
    }
    Future<List<String>?> fetchJapaneseReadings() {
      if (japaneseIndices.isEmpty) return Future.value(null);
      return _phoneticClient.readingsForLines([
        for (final i in japaneseIndices) originalTexts[i],
      ]);
    }

    final readings = List<String?>.filled(originalTexts.length, null);
    final translations = List<String?>.filled(originalTexts.length, null);

    // If the user has supplied their own DeepL key (see SettingsPage), prefer it for the whole
    // song in one call — better quality than ML Kit's English-pivoted on-device models, and it
    // auto-detects each line's language itself, so none of the per-language classification/
    // routing below is needed at all when this succeeds. Only falls through to ML Kit if no
    // key is configured or the call itself failed (network error, revoked key, ...), never
    // because of what language a particular line happens to be.
    final deepLKey = await TranslationKeyStorage.getDeepLKey();
    List<String>? deepLTranslations;
    if (deepLKey != null) {
      deepLTranslations = await _deepLClient.translateLines(originalTexts, deepLKey);
    }

    if (deepLTranslations != null) {
      for (var i = 0; i < originalTexts.length; i++) {
        translations[i] = deepLTranslations[i];
      }
      // Still needed even when DeepL handled translation — 독음 is a separate on-device
      // transliteration this app generates itself, not something DeepL provides.
      final japaneseReadings = await fetchJapaneseReadings();
      if (japaneseReadings != null) {
        for (
          var k = 0;
          k < japaneseIndices.length && k < japaneseReadings.length;
          k++
        ) {
          readings[japaneseIndices[k]] = japaneseReadings[k];
        }
      }
    }

    if (deepLTranslations == null) {
      // Everything left over — not Japanese, not (confidently or promoted) Spanish — is
      // further split into German vs English by ML Kit's own language identifier (see
      // MlKitTranslationClient.classifyGermanVsEnglish) rather than a hand-written detector: a
      // dedicated JapaneseDetector/SpanishDetector per language stopped scaling once a
      // *second* non-Japanese language needed telling apart from English.
      final skipTranslation = {...japaneseIndices, ...spanishIndices};
      final remainingIndices = [
        for (var i = 0; i < originalTexts.length; i++)
          if (!skipTranslation.contains(i)) i,
      ];
      final germanEnglishSplit =
          await _translationClient.classifyGermanVsEnglish(remainingIndices, originalTexts);
      final germanIndices = germanEnglishSplit.german;
      final englishIndices = germanEnglishSplit.english;

      Future<List<String>?> fetchJapaneseTranslations() {
        if (japaneseIndices.isEmpty) return Future.value(null);
        return _translationClient.translateJapaneseLines([
          for (final i in japaneseIndices) originalTexts[i],
        ]);
      }

      Future<List<String>?> fetchEnglishTranslations() {
        if (englishIndices.isEmpty) return Future.value(null);
        return _translationClient.translateEnglishLines([
          for (final i in englishIndices) originalTexts[i],
        ]);
      }

      Future<List<String>?> fetchSpanishTranslations() {
        if (spanishIndices.isEmpty) return Future.value(null);
        return _translationClient.translateSpanishLines([
          for (final i in spanishIndices) originalTexts[i],
        ]);
      }

      Future<List<String>?> fetchGermanTranslations() {
        if (germanIndices.isEmpty) return Future.value(null);
        return _translationClient.translateGermanLines([
          for (final i in germanIndices) originalTexts[i],
        ]);
      }

      final results = await Future.wait([
        fetchJapaneseReadings(),
        fetchJapaneseTranslations(),
        fetchEnglishTranslations(),
        fetchSpanishTranslations(),
        fetchGermanTranslations(),
      ]);
      final japaneseReadings = results[0];
      final japaneseTranslations = results[1];
      final englishTranslations = results[2];
      final spanishTranslations = results[3];
      final germanTranslations = results[4];

      if (japaneseReadings != null) {
        for (
          var k = 0;
          k < japaneseIndices.length && k < japaneseReadings.length;
          k++
        ) {
          readings[japaneseIndices[k]] = japaneseReadings[k];
        }
      }
      if (japaneseTranslations != null) {
        for (
          var k = 0;
          k < japaneseIndices.length && k < japaneseTranslations.length;
          k++
        ) {
          translations[japaneseIndices[k]] = japaneseTranslations[k];
        }
      }
      if (englishTranslations != null) {
        for (
          var k = 0;
          k < englishIndices.length && k < englishTranslations.length;
          k++
        ) {
          translations[englishIndices[k]] = englishTranslations[k];
        }
      }
      if (spanishTranslations != null) {
        for (
          var k = 0;
          k < spanishIndices.length && k < spanishTranslations.length;
          k++
        ) {
          translations[spanishIndices[k]] = spanishTranslations[k];
        }
      }
      if (germanTranslations != null) {
        for (
          var k = 0;
          k < germanIndices.length && k < germanTranslations.length;
          k++
        ) {
          translations[germanIndices[k]] = germanTranslations[k];
        }
      }
    }
    // Synchronous/local, so no need to batch this through Future.wait above the way the
    // native Japanese reading call is — and independent of which translation backend was
    // used, since it's a separate on-device transliteration, not a translation.
    for (final i in spanishIndices) {
      readings[i] = SpanishHangul.transliterateLine(originalTexts[i]);
    }

    final lines = <LyricsLine>[
      for (var i = 0; i < originalTexts.length; i++)
        LyricsLine(
          timestampMs: i < timestamps.length ? timestamps[i] : null,
          original: originalTexts[i],
          phonetic: _nonEmpty(readings[i]),
          translation: _nonEmpty(translations[i]),
        ),
    ];
    return LyricsResult(found: true, lines: lines);
  }

  // An empty/whitespace string isn't null, so without this a tier that came
  // back blank for one particular line would render as a visible blank row
  // instead of being omitted like a genuinely missing tier.
  String? _nonEmpty(String? text) =>
      (text != null && text.trim().isNotEmpty) ? text : null;

  LyricsResult _fromCache(CachedLyricsEntry entry) {
    return LyricsResult(
      found: entry.found,
      fromCache: true,
      isUserPasted: entry.isUserPasted,
      syncOffsetMs: entry.syncOffsetMs,
      lines: [
        for (final line in entry.lines)
          LyricsLine(
            timestampMs: line.timestampMs,
            original: line.original,
            phonetic: line.phonetic,
            translation: line.translation,
          ),
      ],
    );
  }

  CachedLyricsEntry _toCache(LyricsResult result) {
    return CachedLyricsEntry(
      found: result.found,
      cachedAt: DateTime.now(),
      isUserPasted: result.isUserPasted,
      syncOffsetMs: result.syncOffsetMs,
      lines: [
        for (final line in result.lines)
          CachedLyricLine(
            timestampMs: line.timestampMs,
            original: line.original,
            phonetic: line.phonetic,
            translation: line.translation,
          ),
      ],
    );
  }

  // Persists a manual sync correction against whatever's already cached for this song, so the
  // next time it plays the offset is restored instead of starting back at 0 — a no-op if
  // nothing's cached yet for this key (the offset controls only ever show once lyrics are
  // loaded, so this shouldn't normally happen).
  Future<void> updateSyncOffset({
    required String title,
    required String artist,
    required int offsetMs,
  }) async {
    final key = TitleNormalizer.cacheKey(title, artist);
    final existing = _cacheBox.get(key);
    if (existing == null) return;
    await _cacheBox.put(
      key,
      CachedLyricsEntry(
        found: existing.found,
        cachedAt: existing.cachedAt,
        isUserPasted: existing.isUserPasted,
        syncOffsetMs: offsetMs,
        lines: existing.lines,
      ),
    );
  }

  // Corrects a single line's 원문/독음/번역 in place — the timestamp is always left untouched,
  // so a fetched song's sync and every other line stay exactly as they were, even when the
  // original text itself is the thing being corrected. Useful for the common case of the
  // on-device Kuromoji reading getting one word wrong, where discarding the whole song via
  // savePastedLyrics()/refetchFromApi() would be needless. A no-op if the index no longer
  // lines up with what's cached (the song changed underneath, or nothing's cached for this key
  // at all).
  Future<LyricsResult?> updateLine({
    required String title,
    required String artist,
    required int lineIndex,
    String? original,
    String? phonetic,
    String? translation,
  }) async {
    final key = TitleNormalizer.cacheKey(title, artist);
    final existing = _cacheBox.get(key);
    if (existing == null ||
        lineIndex < 0 ||
        lineIndex >= existing.lines.length) {
      return null;
    }
    final updatedLines = List<CachedLyricLine>.from(existing.lines);
    final old = updatedLines[lineIndex];
    // A line with no original text at all doesn't make sense (unlike 독음/번역, which are
    // legitimately optional) — an empty edit is treated as "leave it alone" rather than
    // blanking it out.
    final newOriginal = _nonEmpty(original) ?? old.original;
    updatedLines[lineIndex] = CachedLyricLine(
      timestampMs: old.timestampMs,
      original: newOriginal,
      phonetic: _nonEmpty(phonetic),
      translation: _nonEmpty(translation),
    );
    final updated = CachedLyricsEntry(
      found: existing.found,
      cachedAt: existing.cachedAt,
      isUserPasted: existing.isUserPasted,
      syncOffsetMs: existing.syncOffsetMs,
      lines: updatedLines,
    );
    await _cacheBox.put(key, updated);
    return _fromCache(updated);
  }
}
