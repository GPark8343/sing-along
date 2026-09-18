import 'package:hive_ce_flutter/hive_flutter.dart';

part 'recent_song_entry.g.dart';

/// A lightweight "recently played" index, separate from the lyrics cache itself — keyed by
/// the same cache key ([CachedLyricsEntry] uses, via TitleNormalizer.cacheKey), so replaying
/// a song just updates its [playedAt] instead of creating a duplicate entry. Only [title]/
/// [artist] are duplicated here (for display in the recent-songs list without touching the
/// lyrics box) — the actual lyric lines are looked up from the lyrics cache by [cacheKey] only
/// when the user actually opens one.
@HiveType(typeId: 2)
class RecentSongEntry {
  @HiveField(0)
  final String title;
  @HiveField(1)
  final String artist;
  @HiveField(2)
  final String cacheKey;
  @HiveField(3)
  final DateTime playedAt;

  const RecentSongEntry({
    required this.title,
    required this.artist,
    required this.cacheKey,
    required this.playedAt,
  });
}
