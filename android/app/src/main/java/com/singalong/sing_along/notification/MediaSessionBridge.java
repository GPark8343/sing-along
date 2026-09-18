package com.singalong.sing_along.notification;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.util.ArrayList;
import java.util.List;

/**
 * Process-wide singleton that decouples {@link MediaNotificationListenerService} (which the OS
 * can start independently of any Activity/FlutterEngine) from the Dart-side EventChannel, which
 * only exists while the main app's FlutterEngine is alive. The service always writes here; the
 * MethodChannel/EventChannel handlers registered in MainActivity read/subscribe here whenever
 * the engine happens to be around.
 */
public final class MediaSessionBridge {

    /**
     * How often the real playback position is re-checked while a session is active. This is
     * cheap — {@link android.media.session.MediaController#getPlaybackState()} reads a value
     * already cached locally from the session's last callback, not a fresh cross-process call —
     * so this can run fairly often without meaningfully costing battery/CPU.
     */
    private static final long POLL_INTERVAL_MS = 500;

    public interface Listener {
        void onNowPlayingChanged(NowPlayingInfo info);
    }

    private static final MediaSessionBridge INSTANCE = new MediaSessionBridge();

    public static MediaSessionBridge getInstance() {
        return INSTANCE;
    }

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final List<Listener> listeners = new ArrayList<>();
    private volatile NowPlayingInfo current;
    private MediaNotificationListenerService.PositionSupplier positionSupplier;
    private boolean pollingScheduled = false;

    private MediaSessionBridge() {}

    public synchronized void addListener(Listener listener) {
        listeners.add(listener);
    }

    public synchronized void removeListener(Listener listener) {
        listeners.remove(listener);
    }

    public NowPlayingInfo getCurrent() {
        return current;
    }

    /** Called by the notification listener service whenever the active track/session changes. */
    public void publish(NowPlayingInfo info) {
        current = info;
        notifyListeners(info);
    }

    /** Wired up by the service so the poll loop can pull a fresh position on each tick. */
    void setPositionSupplier(MediaNotificationListenerService.PositionSupplier supplier) {
        this.positionSupplier = supplier;
        schedulePolling();
    }

    void clearPositionSupplier(MediaNotificationListenerService.PositionSupplier supplier) {
        if (this.positionSupplier == supplier) {
            this.positionSupplier = null;
        }
    }

    private void schedulePolling() {
        if (pollingScheduled) return;
        pollingScheduled = true;
        mainHandler.postDelayed(this::pollTick, POLL_INTERVAL_MS);
    }

    private void pollTick() {
        MediaNotificationListenerService.PositionSupplier supplier = positionSupplier;
        if (supplier != null) {
            // currentPosition() legitimately returns null once playback has stopped — that's
            // forwarded like any other update so stale "now playing" state doesn't linger.
            NowPlayingInfo refreshed = supplier.currentPosition();
            current = refreshed;
            notifyListeners(refreshed);
            mainHandler.postDelayed(this::pollTick, POLL_INTERVAL_MS);
        } else {
            pollingScheduled = false;
        }
    }

    private void notifyListeners(NowPlayingInfo info) {
        List<Listener> snapshot;
        synchronized (this) {
            snapshot = new ArrayList<>(listeners);
        }
        for (Listener listener : snapshot) {
            listener.onNowPlayingChanged(info);
        }
    }

    static long nowElapsedRealtime() {
        return SystemClock.elapsedRealtime();
    }
}
