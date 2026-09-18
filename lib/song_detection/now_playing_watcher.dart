import 'dart:async';

import '../core/platform/playback_position_bridge.dart';
import 'now_playing_model.dart';

/// Wraps the raw native playback-position stream with the two shapes the rest of the
/// app actually needs: every position tick (for the M6 sync engine) and de-duplicated
/// track-change events (for triggering the M4/M5 lyrics pipeline only once per song).
class NowPlayingWatcher {
  final Stream<NowPlaying?> positionStream;
  late final Stream<NowPlaying?> trackChanges;

  NowPlayingWatcher({Stream<NowPlaying?>? source})
      : positionStream = (source ?? PlaybackPositionBridge.stream).asBroadcastStream() {
    String? lastKey;
    trackChanges = positionStream.where((event) {
      final key = event?.trackKey;
      final changed = key != lastKey;
      if (changed) lastKey = key;
      return changed;
    }).asBroadcastStream();
  }
}
