import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../core/text/japanese_detector.dart';
import '../../core/text/lrc_parser.dart';
import '../../core/text/spanish_detector.dart';
import '../../core/text/spanish_hangul.dart';
import '../../core/text/title_normalizer.dart';
import '../api/deepl_client.dart';
import '../api/lrclib_client.dart';
import '../hive/models/cached_lyric_line.dart';
import '../hive/models/cached_lyrics_entry.dart';
import '../native/japanese_reading_bridge.dart';

/// One lyric line with whichever tiers were actually available. [phonetic]
/// is only ever set for Japanese songs (computed on-device, no key needed);
/// [translation] only with a DeepL key configured — either can be null
/// independently of the other, and the overlay just omits a tier that's
/// null rather than showing a placeholder for it.
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
/// (독음) and DeepL translation layered on top — each best-effort and
/// independently optional, never blocking the other or the original
/// lyrics themselves.
class LyricsRepository {
  LyricsRepository({
    required this._cacheBox,
    LrclibClient? lrclibClient,
    JapaneseReadingClient? phoneticClient,
    DeepLClient? deepLClient,
  })  : _lrclibClient = lrclibClient ?? LrclibClient(),
        _phoneticClient = phoneticClient ?? JapaneseReadingClient(),
        _deepLClient = deepLClient ?? DeepLClient();

  final Box<CachedLyricsEntry> _cacheBox;
  final LrclibClient _lrclibClient;
  final JapaneseReadingClient _phoneticClient;
  final DeepLClient _deepLClient;

  Future<LyricsResult> getLyrics({
    required String title,
    required String artist,
    int? durationSeconds,
  }) async {
    final key = TitleNormalizer.cacheKey(title, artist);
    final cached = _cacheBox.get(key);
    if (cached != null) return _fromCache(cached);

    final result = await _fetchFresh(title: title, artist: artist, durationSeconds: durationSeconds);
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
    final result = await _fetchFresh(title: title, artist: artist, durationSeconds: durationSeconds);
    await _cacheBox.put(key, _toCache(result));
    return result;
  }

  /// Saves lyrics the user pasted in themselves — LRCLIB matched the wrong song, or didn't have
  /// this one at all, so this goes straight into the same cache slot getLyrics() would have
  /// filled. Deliberately skips the phonetic/translation pipeline entirely (no on-device
  /// Kuromoji pass, no DeepL call) — the user typed/pasted this exact text themselves, so it's
  /// shown back verbatim rather than run through a pipeline built for machine-fetched originals.
  /// No timestamps either (pasted text has no LRC timing), so it's unsynced like any other
  /// plain lyrics — manual left/right tap navigation, not auto-advancing.
  Future<LyricsResult> savePastedLyrics({
    required String title,
    required String artist,
    required String pastedText,
  }) async {
    final originalTexts = pastedText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (originalTexts.isEmpty) return LyricsResult.notFound;
    final result = LyricsResult(
      found: true,
      isUserPasted: true,
      lines: [for (final text in originalTexts) LyricsLine(timestampMs: null, original: text)],
    );
    final key = TitleNormalizer.cacheKey(title, artist);
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
      );
    }

    if (lrclib == null || !lrclib.hasLyrics) {
      lrclib = await _lrclibClient.fetchLyrics(
        trackName: TitleNormalizer.normalizeTitle(title),
        artistName: artistName,
        durationSeconds: durationSeconds,
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

    final parsedLines = LrcParser.parse(lrclib.plainLyrics, lrclib.syncedLyrics);
    if (parsedLines.isEmpty) return LyricsResult.notFound;

    return _buildResult(
      parsedLines.map((line) => line.text).toList(),
      forceUnsynced
          ? List<int?>.filled(parsedLines.length, null)
          : parsedLines.map((line) => line.timestampMs).toList(),
    );
  }

  // Shared by both a fresh LRCLIB fetch and a user-pasted paste-in: runs the on-device
  // phonetic reading (Japanese via Kuromoji, Spanish via rule-based transliteration) + DeepL
  // translation pipeline over whatever original-language lines it's handed, whether they came
  // with LRC timestamps or not.
  Future<LyricsResult> _buildResult(List<String> originalTexts, List<int?> timestamps) async {
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
    final confidentNonJapaneseCount = originalTexts.length - japaneseIndices.length;
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

    final results = await Future.wait([
      fetchJapaneseReadings(),
      _deepLClient.translateLines(originalTexts),
    ]);
    final japaneseReadings = results[0];
    final translations = results[1];

    final readings = List<String?>.filled(originalTexts.length, null);
    if (japaneseReadings != null) {
      for (var k = 0; k < japaneseIndices.length && k < japaneseReadings.length; k++) {
        readings[japaneseIndices[k]] = japaneseReadings[k];
      }
    }
    // Synchronous/local, so no need to batch this through Future.wait above the way the
    // native Japanese reading call is.
    for (final i in spanishIndices) {
      readings[i] = SpanishHangul.transliterateLine(originalTexts[i]);
    }

    final lines = <LyricsLine>[
      for (var i = 0; i < originalTexts.length; i++)
        LyricsLine(
          timestampMs: i < timestamps.length ? timestamps[i] : null,
          original: originalTexts[i],
          phonetic: _nonEmpty(readings[i]),
          translation: _nonEmpty(translations != null ? translations[i] : null),
        ),
    ];
    return LyricsResult(found: true, lines: lines);
  }

  // An empty/whitespace string isn't null, so without this a tier that came
  // back blank for one particular line would render as a visible blank row
  // instead of being omitted like a genuinely missing tier.
  String? _nonEmpty(String? text) => (text != null && text.trim().isNotEmpty) ? text : null;

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
}
