package com.singalong.sing_along.bridge;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationManagerCompat;

import com.singalong.sing_along.MainActivity;
import com.singalong.sing_along.notification.MediaSessionBridge;
import com.singalong.sing_along.notification.NowPlayingInfo;

import java.util.Set;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * MethodChannel "sing_along/notification": permission status/deep-link + a synchronous
 * snapshot of whatever {@link MediaSessionBridge} currently knows, for the main app to poll
 * on resume (the EventChannel only delivers pushes while something is actively listening).
 */
public class NotificationChannelHandler implements MethodChannel.MethodCallHandler {

    public static final String CHANNEL_NAME = "sing_along/notification";

    private final Context appContext;
    private final Activity activity;

    public NotificationChannelHandler(Activity activity) {
        this.activity = activity;
        this.appContext = activity.getApplicationContext();
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "isNotificationAccessGranted":
                result.success(isNotificationAccessGranted());
                break;
            case "openNotificationListenerSettings":
                openNotificationListenerSettings();
                result.success(null);
                break;
            case "getCurrentMedia":
                NowPlayingInfo current = MediaSessionBridge.getInstance().getCurrent();
                result.success(current != null ? current.toMap() : null);
                break;
            case "bringToFront":
                bringMainActivityToFront();
                result.success(null);
                break;
            case "moveTaskToBack":
                // Used by the full-screen lyrics page's back button: a plain Navigator.pop()
                // would just drop back to HomePage within this same Activity, not to whatever
                // app (YouTube Music, say) the user was actually looking at before the overlay's
                // expand button brought this Activity to the front. moveTaskToBack() instead
                // backgrounds the whole task, which is what lets Android reveal that app again.
                result.success(activity.moveTaskToBack(true));
                break;
            default:
                result.notImplemented();
        }
    }

    private boolean isNotificationAccessGranted() {
        Set<String> enabledPackages = NotificationManagerCompat.getEnabledListenerPackages(appContext);
        return enabledPackages.contains(appContext.getPackageName());
    }

    private void openNotificationListenerSettings() {
        Intent intent = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        appContext.startActivity(intent);
    }

    // Called when the user taps "expand" on the floating overlay — the overlay is a separate
    // window/Service, not the Activity, so bringing the full-screen lyrics view up means
    // resurfacing MainActivity itself (it's still running in the background; this doesn't
    // create a new instance, just reorders the existing task to the front).
    private void bringMainActivityToFront() {
        Intent intent = new Intent(appContext, MainActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        appContext.startActivity(intent);
    }
}
