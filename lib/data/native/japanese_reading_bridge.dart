import 'package:flutter/services.dart';

/// Kanji/kana -> Korean phonetic reading (독음), computed entirely on-device via Kuromoji +
/// a hand-written kana->Hangul table on the native side (see JapaneseReadingHandler.java /
/// KanaHangul.java) — no network call, so unlike the old Claude-based pipeline this can't be cut
/// off mid-flight by Android's background process freeze.
class JapaneseReadingClient {
  static const MethodChannel _channel = MethodChannel('sing_along/japanese_reading');

  /// Returns one reading per input line, in the same order — or null if the native call failed
  /// (channel not registered yet, tokenizer error, ...), same contract the old Claude-based
  /// client had, so LyricsRepository can drop the whole phonetic tier for this song rather than
  /// show a partially-misaligned one.
  Future<List<String>?> readingsForLines(List<String> lines) async {
    if (lines.isEmpty) return null;
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('readingsForLines', {'lines': lines});
      if (result == null || result.length != lines.length) return null;
      return result.cast<String>();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
