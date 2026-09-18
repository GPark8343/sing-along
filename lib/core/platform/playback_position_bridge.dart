import 'package:flutter/services.dart';

import '../../song_detection/now_playing_model.dart';

/// Dart-side wrapper for the native `sing_along/playback_position` EventChannel
/// (see `PlaybackPositionStreamHandler.java`). Emits a [NowPlaying] snapshot both on
/// track/metadata change and on the ~3s native poll tick used for drift correction.
class PlaybackPositionBridge {
  PlaybackPositionBridge._();

  static const EventChannel _channel = EventChannel('sing_along/playback_position');

  /// `null` is a real event, not "no data yet" — the native side sends it when playback
  /// stops, so listeners can clear stale "now playing" state instead of freezing on it.
  static Stream<NowPlaying?> get stream => _channel.receiveBroadcastStream().map(
        (event) => event == null ? null : NowPlaying.fromMap(event as Map<dynamic, dynamic>),
      );
}
