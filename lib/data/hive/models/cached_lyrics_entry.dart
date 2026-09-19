import 'package:hive_ce_flutter/hive_flutter.dart';

import 'cached_lyric_line.dart';

part 'cached_lyrics_entry.g.dart';

/// One cache-box entry, keyed by TitleNormalizer.cacheKey — the full
/// pipeline result (LRCLIB + phonetic + translation, whatever tiers were
/// available at fetch time) so a repeat play of the same song is instant
/// and touches no network at all. [found] is cached too, so a song with no
/// lyrics on LRCLIB doesn't get re-queried every time it plays.
@HiveType(typeId: 0)
class CachedLyricsEntry {
  @HiveField(0)
  final bool found;
  @HiveField(1)
  final List<CachedLyricLine> lines;
  @HiveField(2)
  final DateTime cachedAt;
  // defaultValue covers entries cached before this field existed — they're all real fetches,
  // never user-pasted.
  @HiveField(3, defaultValue: false)
  final bool isUserPasted;
  // The user's manual sync correction (see overlay_main.dart/full_screen_lyrics_page.dart),
  // remembered per song so it doesn't need to be re-applied every time the same song plays
  // again — most useful for live recordings, where LRCLIB's timing routinely needs a fixed
  // correction against a particular performance's intro/silence length.
  @HiveField(4, defaultValue: 0)
  final int syncOffsetMs;

  const CachedLyricsEntry({
    required this.found,
    required this.lines,
    required this.cachedAt,
    this.isUserPasted = false,
    this.syncOffsetMs = 0,
  });
}
