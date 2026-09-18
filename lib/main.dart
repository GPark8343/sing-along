import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'app/lyrics/full_screen_lyrics_page.dart';
import 'app/onboarding/permission_screen.dart';
import 'core/platform/notification_bridge.dart';
import 'data/hive/hive_bootstrap.dart';
import 'data/hive/models/cached_lyrics_entry.dart';
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

void main() async {
  // Only the main engine ever touches Hive — see hive_bootstrap.dart.
  WidgetsFlutterBinding.ensureInitialized();
  final lyricsBox = await initHive();
  runApp(SingAlongApp(lyricsBox: lyricsBox));
}

class SingAlongApp extends StatelessWidget {
  const SingAlongApp({super.key, required this.lyricsBox});

  final Box<CachedLyricsEntry> lyricsBox;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sing-along',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: HomePage(lyricsBox: lyricsBox),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.lyricsBox});

  final Box<CachedLyricsEntry> lyricsBox;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  PermissionStatus _permissionStatus =
      const PermissionStatus(notificationAccessGranted: false, overlayGranted: false);
  bool _overlayActive = false;
  NowPlaying? _nowPlaying;
  late final NowPlayingWatcher _watcher;
  late final LyricsRepository _lyricsRepository = LyricsRepository(cacheBox: widget.lyricsBox);
  StreamSubscription<NowPlaying?>? _positionSubscription;
  StreamSubscription<NowPlaying?>? _trackChangeSubscription;
  StreamSubscription<dynamic>? _overlayMessageSubscription;
  String _lyricsStatus = '';
  Map<String, dynamic>? _lastLyricsPayload;
  List<LyricsLine> _currentLyrics = const [];
  bool _expandRequestInFlight = false;
  bool _toggleInFlight = false;
  Timer? _stopDebounceTimer;
  bool _overlayPositionSendInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watcher = NowPlayingWatcher();
    _overlayMessageSubscription = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is! Map) return;
      switch (event['type']) {
        case 'expand':
          _onExpandRequested();
        case 'closed':
          // The overlay's own X button closed it — reflect that immediately rather than
          // waiting for the next _refreshStatus() call (app resume, etc.), otherwise this
          // screen's toggle button keeps reading "오버레이 닫기" for an overlay that's
          // already gone.
          if (mounted) setState(() => _overlayActive = false);
      }
    });
    _positionSubscription = _watcher.positionStream.listen((event) {
      if (!mounted) return;
      setState(() => _nowPlaying = event);
      if (_overlayActive) _sendPositionToOverlay(event);
    });
    _trackChangeSubscription = _watcher.trackChanges.listen(_onTrackChanged);
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSubscription?.cancel();
    _trackChangeSubscription?.cancel();
    _overlayMessageSubscription?.cancel();
    _stopDebounceTimer?.cancel();
    super.dispose();
  }

  // The native side ticks every 16ms, but shareData() is a real cross-engine round trip
  // (JSON encode, dispatch, wait for a reply) that reliably takes longer than that — firing
  // one off on every single tick without waiting for the previous one to land queues up a
  // pile of overlapping sends. Flutter's full-screen page never has this problem (it reads
  // the position stream directly, same engine, no IPC at all), which is exactly why it kept
  // syncing fine while the overlay didn't. Skipping a tick whenever a send is already in
  // flight naturally paces this to whatever the channel can actually keep up with, instead
  // of a fixed interval that might still be too fast on a slower device.
  DateTime? _lastOverlaySendAt; // TEMPORARY diagnostic

  Future<void> _sendPositionToOverlay(NowPlaying? event) async {
    if (_overlayPositionSendInFlight) return;
    _overlayPositionSendInFlight = true;
    try {
      await FlutterOverlayWindow.shareData({
        'type': 'position',
        'trackKey': event?.trackKey,
        'positionMs': event?.positionMs,
        'durationMs': event?.durationMs,
        // Captured right as this engine received the native tick — the
        // overlay adds however long it took THIS ping to actually reach it
        // (the shareData hop between the two engines, which isn't free)
        // back onto positionMs, instead of quietly rendering an
        // already-stale position as if it were current.
        'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      final now = DateTime.now();
      if (_lastOverlaySendAt != null) {
        final gapMs = now.difference(_lastOverlaySendAt!).inMilliseconds;
        if (gapMs > 500) {
          debugPrint('[sing-along] overlay send GAP ${gapMs}ms');
        }
      }
      _lastOverlaySendAt = now;
    } finally {
      _overlayPositionSendInFlight = false;
    }
  }

  Future<void> _onExpandRequested() async {
    // The overlay resends this same request a couple of times to cover a startup-timing gap
    // in the message channel (see _requestExpand in overlay_main.dart) — without this guard,
    // a second copy landing after the first is already mid-flight would push the full-screen
    // route twice.
    if (_expandRequestInFlight) return;
    _expandRequestInFlight = true;
    try {
      // Hide the small card while the full-screen page is up, not just because it'd float on
      // top of our own full-screen content, but because the overlay's TYPE_APPLICATION_OVERLAY
      // window sits above regular app windows regardless of which app is in front.
      await FlutterOverlayWindow.closeOverlay();
      if (mounted) setState(() => _overlayActive = false);
      await NotificationBridge.bringToFront();
      if (mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FullScreenLyricsPage(
            watcher: _watcher,
            lyricsRepository: _lyricsRepository,
            initialNowPlaying: _nowPlaying,
            initialLines: _currentLyrics,
          ),
        ));
      }
    } finally {
      // Guaranteed to clear even if bringToFront/closeOverlay/the route throws — otherwise a
      // single failed attempt would permanently block every future tap behind the in-flight
      // guard above, with no way to recover short of restarting the app.
      _expandRequestInFlight = false;
    }
    // Back from full-screen — restore the compact overlay the same way the toggle button does.
    if (mounted && !_overlayActive) await _toggleOverlay();
  }

  Future<void> _onTrackChanged(NowPlaying? nowPlaying) async {
    if (nowPlaying == null) {
      // A brief "nothing playing" blip — some apps momentarily clear their MediaSession
      // metadata while the user is seeking, which reads identically to "playback stopped" —
      // shouldn't be treated the same as it actually stopping. Wait a beat for a real track
      // to reappear before wiping lyrics/position state out from under the overlay; if it
      // does, this timer gets cancelled below and nothing was ever sent.
      _stopDebounceTimer?.cancel();
      _stopDebounceTimer = Timer(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        setState(() {
          _lyricsStatus = '';
          _currentLyrics = const [];
        });
        _lastLyricsPayload = {'type': 'lyrics', 'found': false, 'title': '', 'artist': ''};
        FlutterOverlayWindow.shareData(_lastLyricsPayload);
      });
      return;
    }
    _stopDebounceTimer?.cancel();
    if (mounted) setState(() => _lyricsStatus = '가사 검색 중...');
    final result = await _lyricsRepository.getLyrics(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      durationSeconds: nowPlaying.durationMs > 0 ? (nowPlaying.durationMs / 1000).round() : null,
    );
    if (mounted) {
      setState(() {
        _lyricsStatus = _statusFor(result);
        _currentLyrics = result.found ? result.lines : const [];
      });
    }
    _lastLyricsPayload = {
      'type': 'lyrics',
      'found': result.found,
      'fromCache': result.fromCache,
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
    final cacheSuffix = result.fromCache ? ' (캐시)' : '';
    if (!result.found) return '가사를 찾을 수 없음$cacheSuffix';
    final hasPhonetic = result.lines.any((line) => line.phonetic != null);
    final hasTranslation = result.lines.any((line) => line.translation != null);
    final tiers = [if (hasPhonetic) '독음', if (hasTranslation) '번역'];
    final tierLabel = tiers.isEmpty ? '원문만' : tiers.join(' · ');
    return '가사 로드됨 · $tierLabel$cacheSuffix';
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
    // A fast double-tap (or a tap landing while _onExpandRequested's own reopen is still
    // running) would otherwise start a second show/close sequence before the first one's
    // native calls and delays have settled, racing them against each other and leaving
    // _overlayActive out of sync with what's actually on screen.
    if (_toggleInFlight) return;
    setState(() => _toggleInFlight = true);
    try {
      await _runToggleOverlay();
    } finally {
      if (mounted) setState(() => _toggleInFlight = false);
    }
  }

  Future<void> _runToggleOverlay() async {
    if (_overlayActive) {
      await FlutterOverlayWindow.closeOverlay();
    } else {
      // showOverlay()'s `height` is consumed as raw physical pixels (unlike
      // the plugin's resizeOverlay(), which runs it through a dp->px
      // conversion), so it has to be scaled by the device's actual pixel
      // ratio to land on a sane logical size. This must stay in sync with
      // OverlayRoot's _maxCardHeight (230dp, sized for a 2-line lyric —
      // see its doc comment) plus ~60dp for SafeArea's status-bar inset.
      // Read the ratio before any `await` so it isn't a stale BuildContext
      // read.
      final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
      final overlayHeightPx = (290 * devicePixelRatio).round();
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
            'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
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
                  onPressed: _toggleInFlight ? null : _toggleOverlay,
                  child: Text(_overlayActive ? '오버레이 닫기' : '오버레이 표시'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
