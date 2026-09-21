/// Cleans up the raw title/artist strings a notification hands us before
/// they're used to query LRCLIB, which needs a fairly close string match.
/// Notification titles carry a lot of noise LRCLIB's own metadata doesn't
/// have — "(Official Video)", "- Live", trailing "- Topic" from YouTube's
/// auto-generated artist channels, multiple co-artists joined together, etc.
class TitleNormalizer {
  TitleNormalizer._();

  // Some Korean-region apps append a Hangul pronunciation guide right after a foreign
  // name — "Luis Fonsi(루이스 폰시)", "Justin Bieber(저스틴 비버)" — which LRCLIB's own
  // metadata never has any idea about. Matched by content (parens containing *only* Hangul
  // and whitespace) rather than needing to know which names this happens to, so it strips
  // cleanly wherever it shows up — including nested inside a "(feat. X(...))" clause, before
  // _featureClause/_multiArtistSplit below ever have to deal with it.
  static final RegExp _hangulReadingParen = RegExp(r'[([（][가-힣\s]+[)\]）]');

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
    result = result.replaceAll(_hangulReadingParen, '');
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
  // "및" is Korean for "and" — some apps localize a multi-artist credit as "Novelbright 및
  // Vaundy" for Korean-region users instead of "&"/"," the way they would for other locales.
  static final RegExp _multiArtistSplit =
      RegExp(r'\s*(?:,|&|/| x | X | 및 |feat\.?|ft\.?|featuring)\s*');

  /// The single primary artist LRCLIB is most likely indexed under — the
  /// first name out of however many the notification's artist field lists.
  static String primaryArtist(String artist) {
    var result = artist;
    result = result.replaceAll(_hangulReadingParen, '');
    result = result.replaceAll(_topicSuffix, '');
    result = result.replaceAll(_vevoSuffix, '');
    result = result.replaceAll(_whitespace, ' ').trim();
    final parts = result.split(_multiArtistSplit);
    final first = parts.firstWhere((part) => part.trim().isNotEmpty, orElse: () => result);
    return first.trim();
  }

  // Captures whatever follows "feat."/"ft."/"featuring" up to a closing bracket or the end of
  // the string — used to pull the featured artist's name back out before normalizeTitle()/
  // primaryArtist() above discard the clause entirely.
  static final RegExp _featureCapture = RegExp(
    r'[-([]?\s*(?:feat\.?|ft\.?|featuring)\s+([^)\]]+)[)\]]?',
    caseSensitive: false,
  );

  /// The featured artist named in a "(feat. X)"/"feat. X" clause, checked in the title first
  /// and then the artist field (a title's own parenthetical is the more common place to see
  /// one) — or null if neither has one. `(feat. X)` means a *specific person actually guested
  /// on this recording*, not just "any song with a similar title/artist" the way a co-equal
  /// multi-artist credit does, so this is kept separate from primaryArtist()'s plain discard:
  /// callers can use it to verify an LRCLIB match's own trackName/artistName actually mentions
  /// that guest too, rather than silently accepting a different recording without them.
  static String? featuredArtist(String title, String artist) {
    // Stripped first so a nested Hangul reading — "(feat. Justin Bieber(저스틴 비버))" —
    // doesn't get swept into the captured name; without this the capture (which stops at the
    // first closing bracket) would grab "Justin Bieber(저스틴 비버" instead of just the name.
    final cleanTitle = title.replaceAll(_hangulReadingParen, '');
    final cleanArtist = artist.replaceAll(_hangulReadingParen, '');
    final fromTitle = _featureCapture.firstMatch(cleanTitle)?.group(1)?.trim();
    if (fromTitle != null && fromTitle.isNotEmpty) return fromTitle;
    final fromArtist = _featureCapture.firstMatch(cleanArtist)?.group(1)?.trim();
    if (fromArtist != null && fromArtist.isNotEmpty) return fromArtist;
    return null;
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
