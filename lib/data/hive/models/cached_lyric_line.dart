import 'package:hive_ce_flutter/hive_flutter.dart';

part 'cached_lyric_line.g.dart';

@HiveType(typeId: 1)
class CachedLyricLine {
  @HiveField(0)
  final int? timestampMs;
  @HiveField(1)
  final String original;
  @HiveField(2)
  final String? phonetic;
  @HiveField(3)
  final String? translation;

  const CachedLyricLine({
    required this.timestampMs,
    required this.original,
    this.phonetic,
    this.translation,
  });
}
