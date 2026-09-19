/// Cleans up the raw title/artist strings a notification hands us before
/// they're used to query LRCLIB, which needs a fairly close string match.
/// Notification titles carry a lot of noise LRCLIB's own metadata doesn't
/// have — "(Official Video)", "- Live", trailing "- Topic" from YouTube's
/// auto-generated artist channels, multiple co-artists joined together, etc.
class TitleNormalizer {
  TitleNormalizer._();

  static final RegExp _liveMarkerPattern = RegExp(
    r'\s*[-–]\s*live\b.*$|\s*\(live[^)]*\)|\s*\[live[^\]]*\]',
    caseSensitive: false,
  );

  // Bracketed/parenthesized noise that never appears in LRCLIB's own
  // trackName field: "(Official Video)", "[Lyric Video]", "(MV)", "(Audio)"...
  static final RegExp _noiseBracket = RegExp(
    r'[([（【][^)\]）】]*\b(official|video|audio|lyrics?|visualizer|mv|performance|ver\.?|version|hd|4k|prod\.?)\b[^)\]）】]*[)\]）】]',
    caseSensitive: false,
  );

  // "feat. X" / "ft. X" / "featuring X" clauses — LRCLIB's trackName is
  // usually just the bare title without the featured-artist clause.
  static final RegExp _featureClause = RegExp(
    r'\s*[-([]?\s*(feat\.?|ft\.?|featuring)\s+[^)\]]*[)\]]?$',
    caseSensitive: false,
  );

  static final RegExp _trailingDescriptor = RegExp(
    r'\s*[-–]\s*(official.*|lyrics?.*|audio.*|mv)$',
    caseSensitive: false,
  );

  static final RegExp _whitespace = RegExp(r'\s+');

  static String normalizeTitle(String title) {
    var result = title;
    result = result.replaceAll(_liveMarkerPattern, '');
    result = result.replaceAll(_noiseBracket, '');
    result = result.replaceAll(_featureClause, '');
    result = result.replaceAll(_trailingDescriptor, '');
    result = result.replaceAll(_whitespace, ' ').trim();
    return result.isEmpty ? title.trim() : result;
  }

  // Deliberately broader than _liveMarkerPattern above (which only matches "live" in the
  // specific trailing/bracketed positions worth stripping for a clean LRCLIB query) — this
  // just needs "live" to appear as its own word anywhere in the title, e.g. "[Official Live
  // Video at ...]" doesn't start with "live" so _liveMarkerPattern's bracket alternative
  // misses it, but this catches it fine. The tradeoff is a song genuinely titled with the
  // word "live" (e.g. "Live Forever") gets flagged too — losing the sync toggle on a studio
  // track is a minor cosmetic cost next to actually mis-syncing a real live performance.
  static final RegExp _liveWordPattern = RegExp(r'\blive\b', caseSensitive: false);

  /// Whether the *raw*, un-normalized title marks this as a live performance — checked
  /// against the original title (normalizeTitle() strips the narrower live marker before
  /// querying LRCLIB, so by the time a query is built there's nothing left here to detect).
  /// Used to force whatever lyrics come back to display unsynced: LRCLIB essentially never
  /// has a separately-timed live submission, so any synced timestamps it returns are the
  /// studio recording's timing, which won't track a live performance's actual pacing.
  static bool isLiveTitle(String title) => _liveWordPattern.hasMatch(title);

  static final RegExp _topicSuffix = RegExp(r'\s*-\s*topic$', caseSensitive: false);
  static final RegExp _vevoSuffix = RegExp(r'\s*vevo$', caseSensitive: false);
  static final RegExp _multiArtistSplit = RegExp(r'\s*(?:,|&|/| x | X |feat\.?|ft\.?|featuring)\s*');

  /// The single primary artist LRCLIB is most likely indexed under — the
  /// first name out of however many the notification's artist field lists.
  static String primaryArtist(String artist) {
    var result = artist;
    result = result.replaceAll(_topicSuffix, '');
    result = result.replaceAll(_vevoSuffix, '');
    result = result.replaceAll(_whitespace, ' ').trim();
    final parts = result.split(_multiArtistSplit);
    final first = parts.firstWhere((part) => part.trim().isNotEmpty, orElse: () => result);
    return first.trim();
  }

  /// The Hive cache key for a song — same normalization as the LRCLIB
  /// query, so a repeat play of a song normalizes to the same key even if
  /// the notification's title/artist strings vary slightly between plays
  /// (e.g. a player occasionally including "(Official Video)").
  static String cacheKey(String title, String artist) {
    final normalizedTitle = normalizeTitle(title).toLowerCase().trim();
    final normalizedArtist = primaryArtist(artist).toLowerCase().trim();
    return '$normalizedTitle::$normalizedArtist';
  }
}
