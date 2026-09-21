/// Reverses a Korean Hangul *phonetic reading* of a foreign name back to an approximate Latin
/// romanization — e.g. "아도" -> "ado" — so it can still be compared against LRCLIB's own
/// Latin/Japanese-script artist field with the same similarity check every other match goes
/// through, rather than having to skip that check for Hangul input entirely (which would lose
/// the ability to reject a same-titled song by a genuinely different artist). Some Korean media
/// apps substitute an artist's name with its Hangul reading for a Korean audience instead of
/// showing the original spelling, which this is built to undo.
///
/// This is Revised Romanization applied to whatever Hangul is present — a real transliteration
/// system, not a lookup table of known artist names — so it works for any name, at the cost of
/// occasionally landing on a slightly different spelling than the artist's own official one
/// (romanization is inherently a many-to-one reduction: several different original spellings
/// can share the same Hangul reading). That's fine here since the result only ever feeds into a
/// fuzzy similarity score, not an exact-match requirement.
class HangulRomanizer {
  HangulRomanizer._();

  static const int _base = 0xAC00;
  static const int _last = 0xD7A3;
  static const int _medialCount = 21;
  static const int _finalCount = 28;

  // Ordered exactly as Unicode enumerates each slot within a Hangul syllable block.
  static const List<String> _initials = [
    'g',
    'kk',
    'n',
    'd',
    'tt',
    'r',
    'm',
    'b',
    'pp',
    's',
    'ss',
    '',
    'j',
    'jj',
    'ch',
    'k',
    't',
    'p',
    'h',
  ];
  static const List<String> _medials = [
    'a',
    'ae',
    'ya',
    'yae',
    'eo',
    'e',
    'yeo',
    'ye',
    'o',
    'wa',
    'wae',
    'oe',
    'yo',
    'u',
    'wo',
    'we',
    'wi',
    'yu',
    'eu',
    'ui',
    'i',
  ];
  static const List<String> _finals = [
    '',
    'k',
    'k',
    'k',
    'n',
    'n',
    'n',
    't',
    'l',
    'k',
    'm',
    'l',
    'l',
    'l',
    'p',
    'l',
    'm',
    'p',
    'p',
    't',
    't',
    'ng',
    't',
    't',
    'k',
    't',
    'p',
    't',
  ];

  static bool _isHangulSyllable(int codeUnit) =>
      codeUnit >= _base && codeUnit <= _last;

  static bool containsHangul(String text) => text.runes.any(_isHangulSyllable);

  /// Romanizes only the Hangul syllables in [text], leaving everything else (spaces, already-
  /// Latin text, punctuation) exactly as it was — a mixed string like "아도 Ado" romanizes
  /// sensibly this way instead of needing to be all-Hangul to work at all.
  static String romanize(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (!_isHangulSyllable(rune)) {
        buffer.writeCharCode(rune);
        continue;
      }
      final offset = rune - _base;
      final finalIndex = offset % _finalCount;
      final medialIndex = (offset ~/ _finalCount) % _medialCount;
      final initialIndex = offset ~/ (_finalCount * _medialCount);
      buffer
        ..write(_initials[initialIndex])
        ..write(_medials[medialIndex])
        ..write(_finals[finalIndex]);
    }
    return buffer.toString();
  }
}
