/// Detects Spanish text without a language-ID package. Spanish uses the same
/// Latin alphabet as English/Portuguese/Italian/French, so unlike
/// [JapaneseDetector] a single distinctive character isn't enough on its
/// own — ñ/¿/¡ are near-certain signals when present, but their absence is
/// common (plenty of Spanish lyrics never use them). Otherwise this falls
/// back to stopword-density scoring across the whole song, which is far
/// more reliable per-line than per-word given how short a single lyric
/// line can be.
class SpanishDetector {
  SpanishDetector._();

  static final RegExp _distinctiveChars = RegExp(r'[ñÑ¿¡]');
  static final RegExp _accentedVowels = RegExp(r'[áéíóúÁÉÍÓÚ]');
  static final RegExp _wordSplit = RegExp(r'[^a-záéíóúñü]+');

  static const Set<String> _stopwords = {
    'de', 'la', 'que', 'el', 'en', 'y', 'a', 'los', 'del', 'las', 'por', 'un',
    'para', 'con', 'no', 'una', 'su', 'al', 'es', 'lo', 'como', 'mas', 'más',
    'pero', 'sus', 'le', 'ya', 'o', 'este', 'si', 'sí', 'porque', 'esta',
    'entre', 'cuando', 'muy', 'sin', 'sobre', 'tambien', 'también', 'me',
    'hasta', 'hay', 'donde', 'quien', 'desde', 'todo', 'nos', 'todos', 'uno',
    'les', 'ni', 'contra', 'otros', 'ese', 'eso', 'ante', 'ellos', 'esto',
    'mi', 'antes', 'algunos', 'unos', 'yo', 'otro', 'otras', 'otra',
    'tanto', 'esa', 'estos', 'mucho', 'nada', 'muchos', 'cual', 'poco',
    'ella', 'estar', 'estas', 'algunas', 'algo', 'nosotros', 'mis', 'tu',
    'te', 'ti', 'tus', 'ellas', 'quiero', 'quieres', 'vida', 'amor', 'eres',
    'estoy', 'vamos', 'soy', 'tengo', 'tienes', 'corazon', 'corazón',
    'siempre', 'nunca', 'ahora', 'asi', 'así', 'bien', 'bailando', 'noche',
  };

  static bool isSpanishLyrics(List<String> lines) => isSpanish(lines.join(' '));

  static bool isSpanish(String text) {
    if (_distinctiveChars.hasMatch(text)) return true;

    final words = text.toLowerCase().split(_wordSplit).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return false;

    var hits = 0;
    for (final w in words) {
      if (_stopwords.contains(w)) hits++;
    }
    if (words.length < 4) {
      return _accentedVowels.hasMatch(text) && hits > 0;
    }
    return hits / words.length >= 0.15;
  }
}
