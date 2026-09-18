import '../../core/text/japanese_detector.dart';
import '../../core/text/lrc_parser.dart';
import '../../core/text/title_normalizer.dart';
import '../api/anthropic_phonetic_client.dart';
import '../api/deepl_client.dart';
import '../api/lrclib_client.dart';

/// One lyric line with whichever tiers were actually available. [phonetic]
/// is only ever set for Japanese songs with an Anthropic key configured;
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

  const LyricsResult({required this.found, required this.lines});

  static const notFound = LyricsResult(found: false, lines: []);
}

/// Single entry point for turning "now playing" into lyrics: LRCLIB for the
/// original text, then Claude (Japanese-only Korean 독음) and DeepL
/// layered on top — each best-effort and independently optional, never
/// blocking the other or the original lyrics themselves. M4 will add a
/// Hive cache-check in front of this same call; callers won't need to
/// change once that lands.
class LyricsRepository {
  LyricsRepository({
    LrclibClient? lrclibClient,
    AnthropicPhoneticClient? phoneticClient,
    DeepLClient? deepLClient,
  })  : _lrclibClient = lrclibClient ?? LrclibClient(),
        _phoneticClient = phoneticClient ?? AnthropicPhoneticClient(),
        _deepLClient = deepLClient ?? DeepLClient();

  final LrclibClient _lrclibClient;
  final AnthropicPhoneticClient _phoneticClient;
  final DeepLClient _deepLClient;

  Future<LyricsResult> getLyrics({
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
  // back blank for one particular line (e.g. Claude echoing a line that's
  // already pure kana back as-is) would render as a visible blank row
  // instead of being omitted like a genuinely missing tier.
  String? _nonEmpty(String? text) => (text != null && text.trim().isNotEmpty) ? text : null;
}
