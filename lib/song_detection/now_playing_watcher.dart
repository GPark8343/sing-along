import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/platform/playback_position_bridge.dart';
import 'now_playing_model.dart';

/// Wraps the raw native playback-position stream with the two shapes the rest of the
/// app actually needs: every position tick (for the M6 sync engine) and de-duplicated
/// track-change events (for triggering the M4/M5 lyrics pipeline only once per song).
class NowPlayingWatcher {
  final Stream<NowPlaying?> positionStream;
  late final Stream<NowPlaying?> trackChanges;

  NowPlayingWatcher({Stream<NowPlaying?>? source})
      : positionStream =
            _diagnosed(source ?? PlaybackPositionBridge.stream).asBroadcastStream() {
    String? lastKey;
    trackChanges = positionStream.where((event) {
      final key = event?.trackKey;
      final changed = key != lastKey;
      if (changed) lastKey = key;
      return changed;
    }).asBroadcastStream();
  }

  // TEMPORARY diagnostic: this is the single shared source every consumer (HomePage, the
  // overlay via shareData, FullScreenLyricsPage) ultimately reads from — logging a gap here
  // tells us whether "stops updating" is a native-polling/EventChannel stall (would show up
  // here) versus something specific to one consumer's own relay path.
  static Stream<NowPlaying?> _diagnosed(Stream<NowPlaying?> source) {
    DateTime? lastTick;
    return source.map((event) {
      final now = DateTime.now();
      if (lastTick != null) {
        final gapMs = now.difference(lastTick!).inMilliseconds;
        if (gapMs > 500) {
          debugPrint('[sing-along] positionStream GAP ${gapMs}ms title=${event?.title} pos=${event?.positionMs}');
        }
      }
      lastTick = now;
      return event;
    });
  }
}
