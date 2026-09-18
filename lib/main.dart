import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'app/onboarding/permission_screen.dart';
import 'core/platform/notification_bridge.dart';
import 'data/repositories/lyrics_repository.dart';
import 'song_detection/now_playing_model.dart';
import 'song_detection/now_playing_watcher.dart';

// A `part` (not a plain import) so overlayMain() lives in this library's
// symbol table — flutter_overlay_window's native side resolves entry points
// by unqualified name against the app's main library, and a plain import
// doesn't re-export symbols into it, which is why a separate imported
// library silently fails to resolve ("Could not resolve main entrypoint
// function") even though the function itself compiles fine.
part 'overlay_main.dart';

void main() {
  runApp(const SingAlongApp());
}

class SingAlongApp extends StatelessWidget {
  const SingAlongApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sing-along',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  PermissionStatus _permissionStatus =
      const PermissionStatus(notificationAccessGranted: false, overlayGranted: false);
  bool _overlayActive = false;
  NowPlaying? _nowPlaying;
  late final NowPlayingWatcher _watcher;
  final LyricsRepository _lyricsRepository = LyricsRepository();
  StreamSubscription<NowPlaying?>? _positionSubscription;
  StreamSubscription<NowPlaying?>? _trackChangeSubscription;
  String _lyricsStatus = '';
  Map<String, dynamic>? _lastLyricsPayload;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watcher = NowPlayingWatcher();
    _positionSubscription = _watcher.positionStream.listen((event) {
      if (!mounted) return;
      setState(() => _nowPlaying = event);
      if (_overlayActive) {
        FlutterOverlayWindow.shareData({
          'type': 'position',
          'trackKey': event?.trackKey,
          'positionMs': event?.positionMs,
          'durationMs': event?.durationMs,
        });
      }
    });
    _trackChangeSubscription = _watcher.trackChanges.listen(_onTrackChanged);
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSubscription?.cancel();
    _trackChangeSubscription?.cancel();
    super.dispose();
  }

  Future<void> _onTrackChanged(NowPlaying? nowPlaying) async {
    if (nowPlaying == null) {
      if (mounted) setState(() => _lyricsStatus = '');
      // Let the overlay clear itself instead of showing a stale song's lyrics.
      _lastLyricsPayload = {'type': 'lyrics', 'found': false, 'title': '', 'artist': ''};
      await FlutterOverlayWindow.shareData(_lastLyricsPayload);
      return;
    }
    if (mounted) setState(() => _lyricsStatus = '가사 검색 중...');
    final result = await _lyricsRepository.getLyrics(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      durationSeconds: nowPlaying.durationMs > 0 ? (nowPlaying.durationMs / 1000).round() : null,
    );
    if (mounted) setState(() => _lyricsStatus = _statusFor(result));
    _lastLyricsPayload = {
      'type': 'lyrics',
      'found': result.found,
      'trackKey': nowPlaying.trackKey,
      'title': nowPlaying.title,
      'artist': nowPlaying.artist ?? '',
      'durationMs': nowPlaying.durationMs,
      'lines': [
        for (final line in result.lines)
          {'t': line.timestampMs, 'o': line.original, 'p': line.phonetic, 'tr': line.translation},
      ],
    };
    // shareData only reaches a listener that's alive *right now* — if the
    // overlay isn't open yet, this is lost, so _toggleOverlay() re-sends
    // this same cached payload once the overlay actually comes up.
    await FlutterOverlayWindow.shareData(_lastLyricsPayload);
  }

  String _statusFor(LyricsResult result) {
    if (!result.found) return '가사를 찾을 수 없음';
    final hasPhonetic = result.lines.any((line) => line.phonetic != null);
    final hasTranslation = result.lines.any((line) => line.translation != null);
    final tiers = [if (hasPhonetic) '독음', if (hasTranslation) '번역'];
    return tiers.isEmpty ? '가사 로드됨 (원문만)' : '가사 로드됨 · ${tiers.join(' · ')}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Both permissions are granted through a system Settings screen, not a runtime
      // dialog, so re-check status whenever the user comes back to the app.
      _refreshStatus();
    }
  }

  Future<void> _refreshStatus() async {
    final results = await Future.wait<dynamic>([
      PermissionStatus.current(),
      FlutterOverlayWindow.isActive(),
      NotificationBridge.getCurrentMedia(),
    ]);
    if (!mounted) return;
    setState(() {
      _permissionStatus = results[0] as PermissionStatus;
      _overlayActive = results[1] as bool;
      // Authoritative snapshot from the native side — including a stop that happened
      // while the app was backgrounded — so this must overwrite, not just fill a gap.
      _nowPlaying = results[2] as NowPlaying?;
    });
  }

  Future<void> _toggleOverlay() async {
    if (_overlayActive) {
      await FlutterOverlayWindow.closeOverlay();
    } else {
      // showOverlay()'s `height` is consumed as raw physical pixels (unlike
      // the plugin's resizeOverlay(), which runs it through a dp->px
      // conversion), so it has to be scaled by the device's actual pixel
      // ratio to land on a sane logical size. This is a fixed window sized
      // for the worst case (OverlayRoot's _maxCardHeight + top-inset/padding
      // margin) — the plugin's resizeOverlay() throws MissingPluginException
      // when called from the overlay isolate, so there's no reliable way to
      // shrink the real window per line; instead the *visible* card inside
      // it sizes itself to content and sits within this fixed budget (see
      // overlay_main.dart). Read the ratio before any `await` so it isn't a
      // stale BuildContext read.
      final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
      final overlayHeightPx = (440 * devicePixelRatio).round();
      // OverlayService self-destructs shortly after creating its window if
      // showOverlay() is called while an instance is already alive natively
      // (e.g. one that survived a force-stop on some OEM skins) — always
      // close first and let the destroy actually land before showing again.
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await FlutterOverlayWindow.showOverlay(
        height: overlayHeightPx,
        alignment: OverlayAlignment.topCenter,
        // Pin the start position explicitly rather than relying on the
        // plugin's default (-statusBarHeight), which assumes top-anchored
        // gravity and pushes a bottom-anchored overlay off-screen — see the
        // note above for bottomCenter's failure mode.
        startPosition: const OverlayPosition(0, 0),
        enableDrag: true,
        overlayTitle: 'sing-along',
        overlayContent: '가사 오버레이가 실행 중입니다',
      );
      // The overlay engine takes a moment to start and register its message
      // handler; resend whatever lyrics we already have once it's had time
      // to come up, since any earlier shareData call would have been missed.
      if (_lastLyricsPayload != null) {
        await Future.delayed(const Duration(milliseconds: 800));
        await FlutterOverlayWindow.shareData(_lastLyricsPayload);
        final current = _nowPlaying;
        if (current != null) {
          await FlutterOverlayWindow.shareData({
            'type': 'position',
            'trackKey': current.trackKey,
            'positionMs': current.positionMs,
            'durationMs': current.durationMs,
          });
        }
      }
    }
    await _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('sing-along')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PermissionOnboarding(
                status: _permissionStatus,
                onRequestNotificationAccess: () async {
                  await NotificationBridge.openNotificationListenerSettings();
                },
                onRequestOverlayPermission: () async {
                  await FlutterOverlayWindow.requestPermission();
                  await _refreshStatus();
                },
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('현재 재생 중', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      if (_nowPlaying == null)
                        const Text('감지된 곡이 없습니다 — 다른 앱에서 음악을 재생해보세요')
                      else ...[
                        Text(_nowPlaying!.title, style: Theme.of(context).textTheme.bodyLarge),
                        Text(_nowPlaying!.artist ?? ''),
                        Text('${(_nowPlaying!.positionMs / 1000).toStringAsFixed(0)}s / '
                            '${(_nowPlaying!.durationMs / 1000).toStringAsFixed(0)}s'),
                        if (_lyricsStatus.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(_lyricsStatus, style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_permissionStatus.overlayGranted)
                ElevatedButton(
                  onPressed: _toggleOverlay,
                  child: Text(_overlayActive ? '오버레이 닫기' : '오버레이 표시'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
