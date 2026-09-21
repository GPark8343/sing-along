/// Detects Japanese text without a language-ID package — checking for
/// hiragana/katakana presence is enough for lyrics, since real Japanese
/// sentences almost always contain kana (particles, verb endings) even
/// when otherwise kanji-heavy, while Chinese (which shares kanji/hanzi)
/// normally doesn't.
class JapaneseDetector {
  JapaneseDetector._();

  static final RegExp _kana = RegExp(r'[぀-ゟ゠-ヿ]');

  static bool isJapanese(String text) => _kana.hasMatch(text);

  static final RegExp _wordPattern = RegExp(r"[A-Za-z']+");

  // Accented Latin letters that never appear in Hepburn-style romaji (which is plain ASCII
  // a-z only) but show up constantly in Portuguese/Spanish/French/etc. lyrics — "não",
  // "batidão", "coração". A vowel-heavy Romance-language song can otherwise trip the
  // vowel-ending-ratio check below almost as easily as real romaji does, and short
  // prepositions like Portuguese "no"/"da" collide with genuine romaji particles ("no" as in
  // の, "da" as in だ), so this is checked first as a hard veto rather than folded into the
  // scoring — any of these characters is proof by itself that the text isn't romaji.
  static final RegExp _romanceDiacritics = RegExp('[àáâãäçèéêëìíîïñòóôõöùúûüýÀÁÂÃÄÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝ]');

  // Function words/particles that show up constantly in romanized Japanese but are
  // essentially never standalone English words on their own — "wo" in particular is
  // basically exclusive to romaji (the を particle), not a real English word.
  static const Set<String> _romajiFunctionWords = {
    'wo', 'wa', 'ga', 'no', 'ni', 'desu', 'masu', 'kara', 'made', 'yo', 'ne', 'da', 'ka',
  };

  /// Heuristic for text that's romanized (romaji) Japanese rather than English or another
  /// Latin-script language — used to catch LRCLIB submissions where the lyrics field was
  /// transcribed as romaji instead of real Japanese script (see LrclibClient), which
  /// [isJapanese] alone can't catch since romaji by definition has no kana/kanji to match.
  /// Requires two independent signals so this doesn't misfire on ordinary English lyrics:
  /// (1) most "words" end in a vowel or 'n' — Japanese mora structure requires that, English
  /// doesn't — and (2) at least two standalone tokens are common Japanese particles.
  static bool looksLikeRomanizedJapanese(String text) {
    if (_romanceDiacritics.hasMatch(text)) return false;
    final words = _wordPattern
        .allMatches(text)
        .map((m) => m.group(0)!)
        .where((w) => w.length >= 2)
        .toList();
    if (words.length < 5) return false;
    final vowelOrNEndingCount = words.where((w) {
      final last = w[w.length - 1].toLowerCase();
      return last == 'a' ||
          last == 'i' ||
          last == 'u' ||
          last == 'e' ||
          last == 'o' ||
          last == 'n';
    }).length;
    if (vowelOrNEndingCount / words.length < 0.85) return false;
    final functionWordHits = words
        .map((w) => w.toLowerCase())
        .where(_romajiFunctionWords.contains)
        .length;
    return functionWordHits >= 2;
  }

  // One Japanese mora: an optional consonant onset (single letter, or one of the digraphs
  // that romanize as two letters — ch/sh/ts/j) followed by a vowel, or the standalone moraic
  // ん ("n"). Doesn't attempt to also match geminate consonants (small っ, e.g. "kekkon") —
  // that's a lyrics-verb-conjugation pattern that essentially never shows up in a stage/artist
  // name, so it's an acceptable gap for what this is actually used for.
  static final RegExp _japaneseNameWordPattern = RegExp(
    r'^(?:(?:ch|sh|ts|j|[kstnhmyrwgzdbpf])?[aiueo]|n)+$',
    caseSensitive: false,
  );

  /// Heuristic for an artist name that's a romanized Japanese name/word — e.g. "Kenshi
  /// Yonezu", "Reira Ushio", "Himehina" — used as a third signal (alongside
  /// [looksLikeRomanizedJapanese] on the lyrics text itself, and comparing an LRCLIB record
  /// against its own title/artist fields) for songs whose title/artist metadata is entirely
  /// already-romanized and so gives [isJapanese] nothing at all to match against directly.
  /// Splits on whitespace/hyphens and on internal lower->upper case changes (so a mashed-
  /// together stage name like "HimeHina" still splits into checkable parts), and requires
  /// every resulting part to independently tile as a sequence of Japanese mora — real Japanese
  /// phonology allows no consonant clusters or non-vowel/non-n word endings, so an ordinary
  /// English/Western name reliably fails this without needing a name database.
  static bool looksLikeJapaneseName(String name) {
    final parts = name
        .split(RegExp(r'[\s_\-]+|(?<=[a-z])(?=[A-Z])'))
        .map((p) => p.trim())
        .where((p) => p.length >= 2)
        .toList();
    if (parts.isEmpty) return false;
    // A short Western first name can coincidentally tile as valid mora too (e.g. "Adele" =
    // a-de-le, "Kesha" = ke-sha) — a real multi-part name ("Kenshi Yonezu") clearing this
    // check on every part is already a fairly strong filter on its own, but a single fused
    // token needs to be long enough that coincidental tiling is actually unlikely.
    if (parts.length == 1 && parts.first.length < 6) return false;
    return parts.every((p) => _japaneseNameWordPattern.hasMatch(p));
  }
}
