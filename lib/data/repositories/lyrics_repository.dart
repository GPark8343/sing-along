import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../core/text/japanese_detector.dart';
import '../../core/text/lrc_parser.dart';
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

  const LyricsResult({
    required this.found,
    required this.lines,
    this.fromCache = false,
    this.isUserPasted = false,
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
    final lrclib = await _lrclibClient.fetchLyrics(
      trackName: TitleNormalizer.normalizeTitle(title),
      artistName: TitleNormalizer.primaryArtist(artist),
      durationSeconds: durationSeconds,
    );
    if (lrclib == null || !lrclib.hasLyrics) return LyricsResult.notFound;

    final parsedLines = LrcParser.parse(lrclib.plainLyrics, lrclib.syncedLyrics);
    if (parsedLines.isEmpty) return LyricsResult.notFound;

    return _buildResult(
      parsedLines.map((line) => line.text).toList(),
      parsedLines.map((line) => line.timestampMs).toList(),
    );
  }

  // Shared by both a fresh LRCLIB fetch and a user-pasted paste-in: runs the same on-device
  // Japanese reading + DeepL translation pipeline over whatever original-language lines it's
  // handed, whether they came with LRC timestamps or not.
  Future<LyricsResult> _buildResult(List<String> originalTexts, List<int?> timestamps) async {
    final isJapanese = originalTexts.any(JapaneseDetector.isJapanese);

    final results = await Future.wait([
      isJapanese ? _phoneticClient.readingsForLines(originalTexts) : Future.value(null),
      _deepLClient.translateLines(originalTexts),
    ]);
    final readings = results[0];
    final translations = results[1];

    final lines = <LyricsLine>[
      for (var i = 0; i < originalTexts.length; i++)
        LyricsLine(
          timestampMs: i < timestamps.length ? timestamps[i] : null,
          original: originalTexts[i],
          phonetic: _nonEmpty(readings != null ? readings[i] : null),
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
}
