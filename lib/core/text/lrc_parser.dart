/// One line of lyrics, before any phonetic/translation tiers are attached.
class LyricLineData {
  final int? timestampMs; // null when the song has no LRC sync data
  final String text;

  const LyricLineData(this.timestampMs, this.text);
}

/// Parses LRCLIB's syncedLyrics ("[mm:ss.xx] line" per line) into timestamped
/// lines, falling back to plainLyrics (no timestamps) when sync data isn't
/// available — the 3-tier fallback's first two tiers.
class LrcParser {
  LrcParser._();

  static final RegExp _lrcLine = RegExp(r'^\[(\d{2}):(\d{2})[.:](\d{2,3})\]\s*(.*)$');

  static List<LyricLineData> parse(String? plainLyrics, String? syncedLyrics) {
    if (syncedLyrics != null && syncedLyrics.trim().isNotEmpty) {
      final lines = <LyricLineData>[];
      for (final raw in syncedLyrics.split('\n')) {
        final match = _lrcLine.firstMatch(raw);
        if (match == null) continue;
        final text = match.group(4)!.trim();
        if (text.isEmpty) continue;
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3)!;
        final millis = fraction.length == 2 ? int.parse(fraction) * 10 : int.parse(fraction);
        lines.add(LyricLineData(minutes * 60000 + seconds * 1000 + millis, text));
      }
      if (lines.isNotEmpty) return lines;
    }
    final plainText = plainLyrics ?? '';
    return plainText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => LyricLineData(null, line))
        .toList();
  }
}
