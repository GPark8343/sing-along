/// Detects Japanese text without a language-ID package — checking for
/// hiragana/katakana presence is enough for lyrics, since real Japanese
/// sentences almost always contain kana (particles, verb endings) even
/// when otherwise kanji-heavy, while Chinese (which shares kanji/hanzi)
/// normally doesn't.
class JapaneseDetector {
  JapaneseDetector._();

  static final RegExp _kana = RegExp(r'[぀-ゟ゠-ヿ]');

  static bool isJapanese(String text) => _kana.hasMatch(text);
}
