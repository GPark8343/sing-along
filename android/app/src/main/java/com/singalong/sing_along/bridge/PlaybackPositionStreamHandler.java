package com.singalong.sing_along.bridge;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.singalong.sing_along.notification.MediaSessionBridge;
import com.singalong.sing_along.notification.NowPlayingInfo;

import io.flutter.plugin.common.EventChannel;

/**
 * EventChannel "sing_along/playback_position": pushes a {@link NowPlayingInfo} snapshot to Dart
 * every time the detected track/metadata changes AND on {@link MediaSessionBridge}'s ~3s poll
 * tick — the same stream feeds both "song changed" detection (M2) and the hybrid sync engine's
 * drift-correction input (M6), since both just need "what is really playing, right now".
 */
public class PlaybackPositionStreamHandler implements EventChannel.StreamHandler {

    private MediaSessionBridge.Listener listener;

    @Override
    public void onListen(Object arguments, @NonNull EventChannel.EventSink events) {
        // A null snapshot is a real event too — it means playback stopped — so it's forwarded
        // as null rather than swallowed, otherwise Dart keeps showing the last song forever.
        listener = info -> events.success(info != null ? info.toMap() : null);
        MediaSessionBridge.getInstance().addListener(listener);
        NowPlayingInfo current = MediaSessionBridge.getInstance().getCurrent();
        events.success(current != null ? current.toMap() : null);
    }

    @Override
    public void onCancel(@Nullable Object arguments) {
        if (listener != null) {
            MediaSessionBridge.getInstance().removeListener(listener);
            listener = null;
        }
    }
}
