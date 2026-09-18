import 'package:flutter/services.dart';

import '../../song_detection/now_playing_model.dart';

/// Dart-side wrapper for the native `sing_along/notification` MethodChannel
/// (see `NotificationChannelHandler.java`). Lives only in the main app engine.
class NotificationBridge {
  NotificationBridge._();

  static const MethodChannel _channel = MethodChannel('sing_along/notification');

  static Future<bool> isNotificationAccessGranted() async {
    final granted = await _channel.invokeMethod<bool>('isNotificationAccessGranted');
    return granted ?? false;
  }

  /// Notification Listener access can only be granted from a system Settings screen,
  /// never a normal runtime permission dialog — this deep-links there.
  static Future<void> openNotificationListenerSettings() async {
    await _channel.invokeMethod('openNotificationListenerSettings');
  }

  /// Synchronous snapshot of whatever the native side currently knows, for polling
  /// on app resume (the EventChannel stream only delivers pushes to active listeners).
  static Future<NowPlaying?> getCurrentMedia() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getCurrentMedia');
    if (result == null) return null;
    return NowPlaying.fromMap(result);
  }

  /// Resurfaces MainActivity (it keeps running in the background even while some other
  /// app is in the foreground) — used when the floating overlay's "expand" button asks
  /// for the full-screen lyrics view, which only the main engine's widget tree can show.
  static Future<void> bringToFront() async {
    await _channel.invokeMethod('bringToFront');
  }

  /// Backgrounds this whole app (moveTaskToBack), rather than just popping a Flutter route —
  /// used by the full-screen lyrics page's back button so it returns to whatever app (e.g.
  /// YouTube Music) was in front before bringToFront() surfaced this one, instead of landing
  /// on this app's own HomePage.
  static Future<void> moveTaskToBack() async {
    await _channel.invokeMethod('moveTaskToBack');
  }
}
