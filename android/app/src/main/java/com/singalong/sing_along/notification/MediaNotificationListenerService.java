package com.singalong.sing_along.notification;

import android.content.ComponentName;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.SystemClock;
import android.service.notification.NotificationListenerService;

import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Zero-cost "now playing" detector: instead of listening to the microphone, this reads the
 * MediaSession metadata exposed alongside the media notification of whatever app is currently
 * playing (YouTube Music, Spotify, ...). Requires the user to grant Notification Access, which
 * is what allows {@link MediaSessionManager#getActiveSessions} to return anything.
 */
public class MediaNotificationListenerService extends NotificationListenerService {

    /** Lets {@link MediaSessionBridge} pull a fresh position snapshot on its 3s poll tick. */
    public interface PositionSupplier {
        NowPlayingInfo currentPosition();
    }

    private MediaSessionManager sessionManager;
    private MediaController activeController;

    private final MediaController.Callback controllerCallback = new MediaController.Callback() {
        @Override
        public void onMetadataChanged(MediaMetadata metadata) {
            publishFrom(activeController, metadata);
        }

        @Override
        public void onPlaybackStateChanged(PlaybackState state) {
            if (state != null && state.getState() != PlaybackState.STATE_PLAYING) {
                // This controller just stopped actively playing (paused, buffering, ...) —
                // pausing one app to go play something in a *different* app (e.g. switching
                // from YouTube Music to Spotify) doesn't reliably fire
                // OnActiveSessionsChangedListener, since the set of active sessions often
                // doesn't actually change — both apps' sessions already existed, only which
                // one is truly playing did. Re-running the full scan here is what catches
                // that handoff instead of leaving this now-paused controller tracked forever.
                // attachController() no-ops if the scan picks this same controller back (by
                // session token), so the publish below is what still reflects its new paused
                // state in that case — without it, the last-published *playing* position
                // would otherwise be left stuck on screen.
                pickActiveSession();
            }
            if (activeController != null) {
                publishFrom(activeController, activeController.getMetadata());
            }
        }

        @Override
        public void onSessionDestroyed() {
            pickActiveSession();
        }
    };

    private final MediaSessionManager.OnActiveSessionsChangedListener sessionsChangedListener =
            controllers -> pickActiveSession();

    private final PositionSupplier positionSupplier =
            () -> activeController != null ? snapshotOf(activeController, activeController.getMetadata()) : null;

    @Override
    public void onListenerConnected() {
        super.onListenerConnected();
        sessionManager = (MediaSessionManager) getSystemService(MEDIA_SESSION_SERVICE);
        ComponentName listenerComponent = new ComponentName(this, MediaNotificationListenerService.class);
        try {
            sessionManager.addOnActiveSessionsChangedListener(sessionsChangedListener, listenerComponent);
            pickActiveSession();
            MediaSessionBridge.getInstance().setPositionSupplier(positionSupplier);
        } catch (SecurityException e) {
            // Notification access was revoked between binding and this call; the onboarding
            // screen will surface the missing permission the next time the app resumes.
        }
    }

    @Override
    public void onListenerDisconnected() {
        if (sessionManager != null) {
            sessionManager.removeOnActiveSessionsChangedListener(sessionsChangedListener);
        }
        detachController();
        MediaSessionBridge.getInstance().publish(null);
        MediaSessionBridge.getInstance().clearPositionSupplier(positionSupplier);
        super.onListenerDisconnected();
    }

    // The main YouTube app is general video, not music — a random video someone's watching has
    // no business triggering a lyrics fetch/overlay the way an actual song does. Dedicated
    // music apps (YouTube Music included) aren't affected: this only excludes this one video
    // app's package, not "any session that happens to be playing a video".
    private static final Set<String> BLOCKED_PACKAGES = new HashSet<>(Arrays.asList(
            "com.google.android.youtube"
    ));

    private void pickActiveSession() {
        if (sessionManager == null) return;
        ComponentName listenerComponent = new ComponentName(this, MediaNotificationListenerService.class);
        List<MediaController> controllers;
        try {
            controllers = sessionManager.getActiveSessions(listenerComponent);
        } catch (SecurityException e) {
            return;
        }
        MediaController next = null;
        MediaController firstEligible = null;
        for (MediaController controller : controllers) {
            if (BLOCKED_PACKAGES.contains(controller.getPackageName())) continue;
            if (firstEligible == null) firstEligible = controller;
            PlaybackState state = controller.getPlaybackState();
            if (state != null && state.getState() == PlaybackState.STATE_PLAYING) {
                next = controller;
                break;
            }
        }
        if (next == null) {
            next = firstEligible;
        }
        attachController(next);
    }

    private void attachController(MediaController controller) {
        // Compare by session token, not package name: an app can destroy and recreate its
        // MediaSession (e.g. its playback service restarting) while keeping the same package,
        // and the old MediaController is then dead — it must not be mistaken for "still attached".
        boolean sameSession = activeController != null && controller != null
                && activeController.getSessionToken().equals(controller.getSessionToken());
        if (sameSession) return;
        detachController();
        activeController = controller;
        if (activeController != null) {
            activeController.registerCallback(controllerCallback);
            publishFrom(activeController, activeController.getMetadata());
        } else {
            // No session left at all (playback stopped / player app closed) — publish the
            // clear explicitly so stale "now playing" state doesn't linger forever downstream.
            MediaSessionBridge.getInstance().publish(null);
        }
    }

    private void detachController() {
        if (activeController != null) {
            activeController.unregisterCallback(controllerCallback);
            activeController = null;
        }
    }

    private void publishFrom(MediaController controller, MediaMetadata metadata) {
        if (controller == null) return;
        MediaSessionBridge.getInstance().publish(snapshotOf(controller, metadata));
    }

    private NowPlayingInfo snapshotOf(MediaController controller, MediaMetadata metadata) {
        String title = metadata != null ? metadata.getString(MediaMetadata.METADATA_KEY_TITLE) : null;
        String artist = metadata != null ? metadata.getString(MediaMetadata.METADATA_KEY_ARTIST) : null;
        long durationMs = metadata != null ? metadata.getLong(MediaMetadata.METADATA_KEY_DURATION) : 0L;
        PlaybackState state = controller.getPlaybackState();
        long positionMs = extrapolatedPosition(state);
        return new NowPlayingInfo(
                controller.getPackageName(),
                title,
                artist,
                durationMs,
                positionMs,
                MediaSessionBridge.nowElapsedRealtime());
    }

    /**
     * {@link PlaybackState#getPosition()} is the position as of the session's last report, not
     * "right now" — a session that only reports once every few seconds would otherwise always
     * look like it's lagging behind by however long it's been since that report. Project it
     * forward using the session's own last-update timestamp and playback speed instead of
     * trusting the raw value, so a coarse poll interval still yields an accurate line.
     */
    private long extrapolatedPosition(PlaybackState state) {
        if (state == null) return 0L;
        if (state.getState() != PlaybackState.STATE_PLAYING) return state.getPosition();
        long elapsedSinceReport = MediaSessionBridge.nowElapsedRealtime() - state.getLastPositionUpdateTime();
        if (elapsedSinceReport < 0) return state.getPosition(); // clock skew guard
        return state.getPosition() + (long) (elapsedSinceReport * state.getPlaybackSpeed());
    }
}
