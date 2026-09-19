import 'package:dio/dio.dart';

import '../../core/text/japanese_detector.dart';

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

  bool get hasSyncedLyrics => syncedLyrics?.trim().isNotEmpty ?? false;

  bool get hasLyrics => !instrumental && (hasSyncedLyrics || (plainLyrics?.trim().isNotEmpty ?? false));
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
    final exact = await _getExact(trackName, artistName, durationSeconds) ??
        await _getExact(trackName, artistName, null);

    // /get returns exactly one record — there's nothing to prefer among alternatives the
    // way there is with /search below. But LRCLIB often has more than one submission for the
    // same song (different contributors, some plain-only, some synced), and /get isn't
    // guaranteed to be the synced one even when a synced version exists under a different
    // record. A synced result is worth a lot more than the marginal cost of one extra
    // request, so when the exact hit lacks sync, check whether search can do better before
    // settling for plain.
    if (exact != null && exact.hasSyncedLyrics) return exact;

    final candidates = _titleCandidates(trackName, artistName);
    final searched = await _searchBestAcross(candidates, artistName, trackName, artistName, durationSeconds) ??
        (artistName.isNotEmpty
            ? await _searchBestAcross(candidates, '', trackName, artistName, durationSeconds)
            : null);

    if (searched != null && searched.hasSyncedLyrics) return searched;
    // Neither source had a synced version — fall back to whichever had lyrics at all,
    // preferring the exact match since it's the more precisely-identified record.
    return exact ?? searched;
  }

  // A YouTube-style "Artist - Title" notification title, once normalized, still splits into
  // ["Artist", "Title"] here — searching LRCLIB with the artist fragment AS a title candidate
  // is worse than just skipping it: LRCLIB submissions often carry that same "Artist - Title"
  // convention in their own trackName field, so an "artist name" candidate can score a
  // deceptively high partial match against a *completely different song* by that artist
  // (the shared "Artist - " prefix, plus the artist-name score already maxed out from a
  // perfect artist match) — exactly the "matched the wrong song" failure mode this is guarding
  // against, not a genuine alternate phrasing of the real title.
  List<String> _titleCandidates(String trackName, String artistName) {
    final candidates = <String>[trackName];
    for (final part in trackName.split(_titleSplitPattern)) {
      final trimmed = part.trim();
      if (trimmed.isEmpty || candidates.contains(trimmed)) continue;
      if (artistName.isNotEmpty && _similarity(trimmed, artistName) > 0.8) continue;
      candidates.add(trimmed);
    }
    return candidates;
  }

  // queryArtist and scoringArtist are deliberately separate: queryArtist narrows the actual
  // LRCLIB /search request (empty widens it, for when the real artist string doesn't resemble
  // LRCLIB's own record closely enough for its search to find anything). scoringArtist is
  // always the real artist we're actually looking for, regardless of what the query used —
  // scoring against an empty artist made every result's artist score an automatic 1.0, which
  // meant an artist-less search for a common title (e.g. "Caravan", a jazz standard with
  // dozens of unrelated submissions) would score any of them as a "perfect" match.
  Future<LrclibLyrics?> _searchBestAcross(
    List<String> titleCandidates,
    String queryArtist,
    String originalTrackName,
    String scoringArtist,
    int? durationSeconds,
  ) async {
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    for (final candidate in titleCandidates) {
      final result = await _search(candidate, queryArtist);
      for (final entry in result) {
        // Skip rather than let a low score naturally lose — a romanized-lyrics submission of
        // the *right* song can still score highest on title/artist similarity (it's the same
        // song, just the wrong lyrics field), so this has to disqualify it outright instead of
        // trusting the score to sort it out.
        if (_isRomanizedMismatch(entry, originalTrackName, scoringArtist)) continue;
        final score = _matchScore(candidate, scoringArtist, durationSeconds, entry);
        if (score > bestScore) {
          bestScore = score;
          best = entry;
        }
      }
    }
    // Strict on purpose: showing a completely different song's lyrics with
    // full confidence is worse than honestly saying "not found" — a listener
    // can tell the difference between "no lyrics" and "wrong lyrics" only by
    // already knowing the song, which defeats the point of the app.
    if (best == null || bestScore < 0.75) return null;
    return _parse(best);
  }

  Future<LrclibLyrics?> _getExact(String trackName, String artistName, int? durationSeconds) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/get', queryParameters: {
        'track_name': trackName,
        'artist_name': artistName,
        'duration': ?durationSeconds,
      });
      final data = response.data!;
      if (_isRomanizedMismatch(data, trackName, artistName)) return null;
      return _parse(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      return null; // network/timeout — treat as "not found for now", not fatal
    }
  }

  // LRCLIB occasionally has a submission where the lyrics text is a romanized (romaji)
  // transcription instead of the real target-language script — most visibly for Japanese
  // songs. That's a different (wrong) submission, not a language choice this app should just
  // accept: scrolling English-letter "pronunciation" as the 원문 defeats the whole point of
  // the 원문/독음 split (and JapaneseDetector.isJapanese never sees any kana to trigger the
  // 독음 tier on, so it would otherwise silently degrade to 2-tier with the wrong original).
  // Four independent signals, any one enough to reject the candidate:
  //  1. Query title — the *notification's own* title already has kana in it (e.g. "テトリス -
  //     Tetoris"), which is about as direct a signal as this gets: whatever the record itself
  //     looks like, the song we're actually trying to match is Japanese. Checked first since
  //     it needs no guessing at all, unlike 2-4 below.
  //  2. Self-consistency — the record's own trackName/artistName are in Japanese (kana), but
  //     its lyrics field isn't. Needs no assumption about what script the *query* used either.
  //  3. Content shape — some submissions are romanized end-to-end (trackName/artistName *and*
  //     lyrics all in Latin script, e.g. Kenshi Yonezu's "Lemon"), where 1-2 have nothing to
  //     compare against — JapaneseDetector.looksLikeRomanizedJapanese catches those directly
  //     from the lyrics text's own phonetic shape instead.
  //  4. Artist name shape — for when even the query title/artist are already fully romanized
  //     with no kana or distinctive Japanese particles anywhere (e.g. HIMEHINA's "Lemonade",
  //     whose lyrics are genuinely almost all English) — JapaneseDetector.looksLikeJapaneseName
  //     catches those from the artist name's own phonetic shape instead.
  bool _isRomanizedMismatch(Map<String, dynamic> result, String queryTitle, String queryArtist) {
    final syncedLyrics = result['syncedLyrics'] as String?;
    final lyrics = (syncedLyrics?.trim().isNotEmpty ?? false)
        ? syncedLyrics!
        : (result['plainLyrics'] as String? ?? '');
    if (lyrics.trim().isEmpty || JapaneseDetector.isJapanese(lyrics)) {
      return false; // empty, or already has real kana — nothing to flag
    }
    if (JapaneseDetector.isJapanese(queryTitle)) return true;
    final recordTitle = (result['trackName'] as String?) ?? '';
    final recordArtist = (result['artistName'] as String?) ?? '';
    final recordIsJapanese =
        JapaneseDetector.isJapanese(recordTitle) || JapaneseDetector.isJapanese(recordArtist);
    return recordIsJapanese ||
        JapaneseDetector.looksLikeRomanizedJapanese(lyrics) ||
        JapaneseDetector.looksLikeJapaneseName(queryArtist);
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
      if (resultDuration != null) {
        // LRCLIB routinely has several submissions of the exact same song (different
        // contributors, or genuinely different cuts — a radio edit vs. the full version, a
        // studio track vs. a live recording someone mislabeled) that title/artist similarity
        // alone can't tell apart, since they're all identical on that front. Duration is the
        // one signal left to prefer the submission that's actually the same recording as
        // what's playing: a smooth bonus that peaks at an exact match and fades out by 15s
        // off, rather than a flat all-or-nothing threshold, so it keeps discriminating even
        // between two candidates that are both "close".
        final diffSeconds = (resultDuration - durationSeconds).abs();
        final durationBonus = (1 - (diffSeconds / 15)).clamp(0.0, 1.0) * 0.08;
        score += durationBonus;
      }
    }
    // A small nudge, not a rescue — this only ever breaks a near-tie between two otherwise
    // similarly-matching submissions of the same song in favor of the synced one, it can't
    // push a genuinely poor title/artist match over the acceptance threshold on its own.
    if ((result['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false) {
      score += 0.03;
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
