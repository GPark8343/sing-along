/// Snapshot of whatever is currently playing in another app, as reported by
/// the native MediaSession bridge (`MediaSessionBridge.toMap()` on the Java side).
class NowPlaying {
  final String? packageName;
  final String title;
  final String? artist;
  final int durationMs;
  final int positionMs;

  /// `SystemClock.elapsedRealtime()` at the moment this snapshot was captured natively —
  /// used by the sync engine to compensate for channel/relay latency, not wall-clock time.
  final int capturedAtElapsedRealtime;

  const NowPlaying({
    required this.packageName,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.positionMs,
    required this.capturedAtElapsedRealtime,
  });

  factory NowPlaying.fromMap(Map<dynamic, dynamic> map) {
    return NowPlaying(
      packageName: map['packageName'] as String?,
      title: (map['title'] as String?) ?? '',
      artist: map['artist'] as String?,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      capturedAtElapsedRealtime: (map['capturedAtElapsedRealtime'] as num?)?.toInt() ?? 0,
    );
  }

  /// Identity used to detect a track change, independent of playback position ticks.
  String get trackKey => '${artist ?? ''}::$title';

  @override
  String toString() => 'NowPlaying($title / $artist, pos=${positionMs}ms)';
}
