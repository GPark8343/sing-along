/// Detects Spanish text without a language-ID package. Spanish uses the same Latin alphabet
/// as English/Portuguese/Italian/French, so unlike [JapaneseDetector] a single distinctive
/// character isn't enough on its own — ñ/¿/¡/accented vowels are near-certain signals when
/// present, but their absence is common (plenty of Spanish lyrics never use them).
///
/// Checked one LINE at a time, deliberately — an earlier version of this scored stopword
/// density across a whole song at once, which meant a handful of Spanish lines could tip an
/// otherwise-English song's *entire* lyrics into being run through the Spanish phonetic
/// pipeline (and vice versa), producing a nonsense 독음 for every English line in the song.
/// Judging each line independently means a song can freely mix Spanish, English and other
/// languages line by line, each only getting the phonetic treatment that's actually right
/// for it.
class SpanishDetector {
  SpanishDetector._();

  static final RegExp _distinctiveChars = RegExp(r'[ñÑ¿¡]');
  static final RegExp _accentedVowels = RegExp(r'[áéíóúÁÉÍÓÚüÜ]');
  static final RegExp _wordSplit = RegExp(r"[^a-záéíóúñü']+");

  // Deliberately excludes anything that doubles as a common standalone English word or a
  // filler syllable that shows up in English-language lyrics just as often — "a", "no", "la",
  // "en", "un", "y", "o", "me" are all real Spanish stopwords too, but "la la la" and "no no
  // no" are everyday English pop filler, "a"/"me" are among the most common English words
  // outright, and "en"/"un"/"y"/"o" are common abbreviations/initials. Keeping those out is
  // what keeps this from false-positiving on English lyrics the way the whole-song version
  // did.
  static const Set<String> _stopwords = {
    'que', 'el', 'los', 'las', 'del', 'por', 'para', 'con', 'una', 'su', 'al',
    'lo', 'como', 'pero', 'sus', 'porque', 'esta', 'está', 'entre', 'cuando',
    'muy', 'sin', 'sobre', 'también', 'hasta', 'donde', 'desde', 'todos',
    'otros', 'ese', 'eso', 'ante', 'esto', 'tanto', 'esa', 'estos', 'mucho',
    'nada', 'algo', 'nosotros', 'tus', 'ellas', 'quiero', 'quieres', 'corazón',
    'siempre', 'nunca', 'así', 'bailando', 'mi', 'te', 'ti', 'yo', 'eres',
    'estoy', 'vamos', 'soy', 'tengo', 'tienes', 'ahora', 'bien', 'noche',
    'vida', 'amor', 'nos', 'les', 'ella', 'estas', 'algunas', 'algunos',
  };

  static bool isSpanish(String text) {
    if (_distinctiveChars.hasMatch(text) || _accentedVowels.hasMatch(text)) {
      return true;
    }
    final words = _words(text);
    if (words.length < 2) return false;
    // An absolute count rather than a density ratio — a single lyric line is often only 4-8
    // words, short enough that one coincidental match would swing a ratio-based threshold
    // wildly. Two independent, unambiguous Spanish-only words is a much steadier bar
    // regardless of how long the line happens to be.
    final hits = words.where(_stopwords.contains).length;
    return hits >= 2;
  }

  // A weaker signal than isSpanish() — one stopword match instead of two, a single word that
  // isn't recognizable as anything (a repeated one-word hook/title line, e.g. a chorus built
  // around just "Despacito" over and over), or a line built entirely out of content words with
  // no grammatical stopword at all but that still has the right *shape* for Spanish (see
  // _looksLikeSpanishWordShape) — "pasito a pasito, suave suavecito" is genuine Spanish but
  // has no article/preposition/pronoun for the stopword list to catch. Deliberately not
  // trusted on its own — this many false positives on a real English line would reintroduce
  // the exact bug per-line detection was built to fix. Only meant to be promoted to Spanish
  // when the rest of the song already leans confidently Spanish (see
  // LyricsRepository._buildResult), i.e. as a tie-breaker for lines too ambiguous to judge on
  // their own, not as an independent detector.
  static bool isMaybeSpanish(String text) {
    final words = _words(text);
    if (words.isEmpty) return false;
    if (words.length == 1 || words.any(_stopwords.contains)) return true;
    return _looksLikeSpanishWordShape(words);
  }

  // Spanish words overwhelmingly end in a vowel, or one of a handful of consonants (n, s, r,
  // d, l, z — mostly plural -s and infinitive/agent endings) — English has nowhere near that
  // regularity (consonant-heavy endings like "-th", "-ck", "-ng", "-st" are everyday there).
  // Requiring a high fraction of a line's words to fit that shape is what lets this catch
  // Spanish content words a stopword list alone never will, without also catching ordinary
  // English lines — every English example this was checked against (verse lines from an
  // actual English/Spanish bilingual remix) scored well under the threshold used here.
  static bool _looksLikeSpanishWordShape(List<String> words) {
    if (words.length < 2) return false;
    const okEndings = {'a', 'e', 'i', 'o', 'u', 'n', 's', 'r', 'd', 'l', 'z'};
    final fits = words.where((w) => okEndings.contains(w[w.length - 1])).length;
    return fits / words.length >= 0.85;
  }

  static List<String> _words(String text) => text
      .toLowerCase()
      .split(_wordSplit)
      .where((w) => w.length >= 2)
      .toList();
}
