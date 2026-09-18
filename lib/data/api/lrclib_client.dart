import 'package:dio/dio.dart';

/// Raw lyrics as returned by LRCLIB — no auth/rate limit, so no key handling
/// needed for this leg of the pipeline (unlike Goo Lab/DeepL later).
class LrclibLyrics {
  final String? plainLyrics;
  final String? syncedLyrics; // LRC text: "[mm:ss.xx] line" per line, when available
  final bool instrumental;

  const LrclibLyrics({
    required this.plainLyrics,
    required this.syncedLyrics,
    required this.instrumental,
  });

  bool get hasLyrics =>
      !instrumental && ((plainLyrics?.trim().isNotEmpty ?? false) || (syncedLyrics?.trim().isNotEmpty ?? false));
}

class LrclibClient {
  LrclibClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://lrclib.net/api',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ));

  final Dio _dio;

  static final RegExp _titleSplitPattern = RegExp(r'\s*[-–/／]\s*');

  /// Notification titles/artists rarely match LRCLIB's own metadata
  /// character-for-character (extra "(Official Video)", a duration that's
  /// off by a couple seconds, "Artist - Topic" from YouTube, ...), so this
  /// tries progressively looser lookups rather than giving up after the
  /// first exact-match miss:
  ///   1. exact `/get` with duration (fastest, most precise)
  ///   2. exact `/get` without duration (title/artist matched, but our
  ///      reported duration was off)
  ///   3. `/search` against every "title candidate" — the full title, plus
  ///      each side of it split on "-"/"/" for bilingual titles like "ロッ
  ///      クスター - ROCKSTAR" (LRCLIB's own search returns nothing for the
  ///      combined string but finds it instantly from either half alone) —
  ///      scored by string similarity across every candidate's results
  ///      rather than trusting whichever query happens to return first
  ///   4. the same candidate sweep again without the artist, for when the
  ///      artist string itself doesn't resemble LRCLIB's record at all
  Future<LrclibLyrics?> fetchLyrics({
    required String trackName,
    required String artistName,
    int? durationSeconds,
  }) async {
    final exactWithDuration = await _getExact(trackName, artistName, durationSeconds);
    if (exactWithDuration != null) return exactWithDuration;

    final exactNoDuration = await _getExact(trackName, artistName, null);
    if (exactNoDuration != null) return exactNoDuration;

    final candidates = _titleCandidates(trackName);

    final searched = await _searchBestAcross(candidates, artistName, durationSeconds);
    if (searched != null) return searched;

    if (artistName.isNotEmpty) {
      return _searchBestAcross(candidates, '', durationSeconds);
    }
    return null;
  }

  List<String> _titleCandidates(String trackName) {
    final candidates = <String>[trackName];
    for (final part in trackName.split(_titleSplitPattern)) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty && !candidates.contains(trimmed)) {
        candidates.add(trimmed);
      }
    }
    return candidates;
  }

  Future<LrclibLyrics?> _searchBestAcross(
    List<String> titleCandidates,
    String artistName,
    int? durationSeconds,
  ) async {
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    for (final candidate in titleCandidates) {
      final result = await _search(candidate, artistName);
      for (final entry in result) {
        final score = _matchScore(candidate, artistName, durationSeconds, entry);
        if (score > bestScore) {
          bestScore = score;
          best = entry;
        }
      }
    }
    // Below this, the "best" result is more likely a wrong song than a
    // messily-formatted title of the right one.
    if (best == null || bestScore < 0.45) return null;
    return _parse(best);
  }

  Future<LrclibLyrics?> _getExact(String trackName, String artistName, int? durationSeconds) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/get', queryParameters: {
        'track_name': trackName,
        'artist_name': artistName,
        'duration': ?durationSeconds,
      });
      return _parse(response.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      return null; // network/timeout — treat as "not found for now", not fatal
    }
  }

  Future<List<Map<String, dynamic>>> _search(String trackName, String artistName) async {
    try {
      final response = await _dio.get<List<dynamic>>('/search', queryParameters: {
        'track_name': trackName,
        'artist_name': ?artistName.isEmpty ? null : artistName,
      });
      return (response.data ?? const []).cast<Map<String, dynamic>>();
    } on DioException {
      return const [];
    }
  }

  double _matchScore(String trackName, String artistName, int? durationSeconds, Map<String, dynamic> result) {
    final titleScore = _similarity(trackName, (result['trackName'] as String?) ?? '');
    final artistScore = artistName.isEmpty ? 1.0 : _similarity(artistName, (result['artistName'] as String?) ?? '');
    var score = titleScore * 0.65 + artistScore * 0.35;
    if (durationSeconds != null) {
      final resultDuration = (result['duration'] as num?)?.toInt();
      if (resultDuration != null && (resultDuration - durationSeconds).abs() <= 3) {
        score += 0.05; // tie-break nudge for a close duration match
      }
    }
    return score;
  }

  /// 1 - normalized Levenshtein distance, case/whitespace-insensitive.
  double _similarity(String a, String b) {
    final normalizedA = a.toLowerCase().trim();
    final normalizedB = b.toLowerCase().trim();
    if (normalizedA.isEmpty || normalizedB.isEmpty) return 0;
    if (normalizedA == normalizedB) return 1;
    final maxLength = normalizedA.length > normalizedB.length ? normalizedA.length : normalizedB.length;
    return 1 - (_levenshtein(normalizedA, normalizedB) / maxLength);
  }

  int _levenshtein(String a, String b) {
    var previousRow = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final currentRow = List<int>.filled(b.length + 1, 0);
      currentRow[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1;
        currentRow[j] = [
          currentRow[j - 1] + 1, // insertion
          previousRow[j] + 1, // deletion
          previousRow[j - 1] + substitutionCost, // substitution
        ].reduce((x, y) => x < y ? x : y);
      }
      previousRow = currentRow;
    }
    return previousRow[b.length];
  }

  LrclibLyrics _parse(Map<String, dynamic> json) {
    return LrclibLyrics(
      plainLyrics: json['plainLyrics'] as String?,
      syncedLyrics: json['syncedLyrics'] as String?,
      instrumental: json['instrumental'] as bool? ?? false,
    );
  }
}
