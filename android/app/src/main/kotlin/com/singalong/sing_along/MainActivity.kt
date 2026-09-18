package com.singalong.sing_along

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.singalong.sing_along.bridge.NotificationChannelHandler
import com.singalong.sing_along.bridge.PlaybackPositionStreamHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+ (API 33) requires this as a normal runtime permission, or the
        // overlay's foreground service notification is silently suppressed by the OS.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NotificationChannelHandler.CHANNEL_NAME
        ).setMethodCallHandler(NotificationChannelHandler(this))

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sing_along/playback_position"
        ).setStreamHandler(PlaybackPositionStreamHandler())
    }
}
