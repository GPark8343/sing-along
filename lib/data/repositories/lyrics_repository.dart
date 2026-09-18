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

  const LyricsResult({required this.found, required this.lines, this.fromCache = false});

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

    final originalTexts = parsedLines.map((line) => line.text).toList();
    final isJapanese = originalTexts.any(JapaneseDetector.isJapanese);

    final results = await Future.wait([
      isJapanese ? _phoneticClient.readingsForLines(originalTexts) : Future.value(null),
      _deepLClient.translateLines(originalTexts),
    ]);
    final readings = results[0];
    final translations = results[1];

    final lines = <LyricsLine>[
      for (var i = 0; i < parsedLines.length; i++)
        LyricsLine(
          timestampMs: parsedLines[i].timestampMs,
          original: parsedLines[i].text,
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
