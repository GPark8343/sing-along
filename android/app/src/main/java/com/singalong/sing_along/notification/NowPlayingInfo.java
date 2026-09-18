package com.singalong.sing_along.notification;

import java.util.HashMap;
import java.util.Map;

/** Snapshot of the currently playing media session, extracted without touching the microphone. */
public class NowPlayingInfo {
    public final String packageName;
    public final String title;
    public final String artist;
    public final long durationMs;
    public final long positionMs;
    public final long capturedAtElapsedRealtime;

    public NowPlayingInfo(
            String packageName,
            String title,
            String artist,
            long durationMs,
            long positionMs,
            long capturedAtElapsedRealtime) {
        this.packageName = packageName;
        this.title = title;
        this.artist = artist;
        this.durationMs = durationMs;
        this.positionMs = positionMs;
        this.capturedAtElapsedRealtime = capturedAtElapsedRealtime;
    }

    public Map<String, Object> toMap() {
        Map<String, Object> map = new HashMap<>();
        map.put("packageName", packageName);
        map.put("title", title);
        map.put("artist", artist);
        map.put("durationMs", durationMs);
        map.put("positionMs", positionMs);
        map.put("capturedAtElapsedRealtime", capturedAtElapsedRealtime);
        return map;
    }
}
