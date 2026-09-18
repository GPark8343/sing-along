import '../../core/text/title_normalizer.dart';
import '../api/lrclib_client.dart';

/// Single entry point for turning "now playing" into lyrics. For M3 this is
/// just the LRCLIB leg with no caching; M4 adds a Hive cache-check in front
/// of this same call, and M5 chains Goo Lab/DeepL after it — callers won't
/// need to change once those land.
class LyricsRepository {
  LyricsRepository({LrclibClient? lrclibClient}) : _lrclibClient = lrclibClient ?? LrclibClient();

  final LrclibClient _lrclibClient;

  Future<LrclibLyrics?> getLyrics({
    required String title,
    required String artist,
    int? durationSeconds,
  }) {
    return _lrclibClient.fetchLyrics(
      trackName: TitleNormalizer.normalizeTitle(title),
      artistName: TitleNormalizer.primaryArtist(artist),
      durationSeconds: durationSeconds,
    );
  }
}
