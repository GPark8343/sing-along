import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'app/lyrics/full_screen_lyrics_page.dart';
import 'app/lyrics/saved_lyrics_view_page.dart';
import 'app/lyrics/saved_songs_list_page.dart';
import 'app/onboarding/permission_screen.dart';
import 'app/theme/metal_theme.dart';
import 'core/platform/notification_bridge.dart';
import 'core/text/title_normalizer.dart';
import 'data/hive/hive_bootstrap.dart';
import 'data/hive/models/recent_song_entry.dart';
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
  // Every screen in the main engine shares the same MetalTheme.base background, so this is set
  // once globally rather than per-page — otherwise the system nav bar defaults to its own
  // light/gray chrome, which stands out against the app's dark theme.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: MetalTheme.base,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: MetalTheme.base,
      // On Android 15+ (edge-to-edge enforced for apps targeting API 35+, which this one
      // does), the OS paints a translucent contrast scrim over the nav bar color by default —
      // without turning that off, our exact color gets washed out lighter than intended.
      systemNavigationBarContrastEnforced: false,
    ),
  );
  final boxes = await initHive();
  runApp(SingAlongApp(boxes: boxes));
}

class SingAlongApp extends StatelessWidget {
  const SingAlongApp({super.key, required this.boxes});

  final HiveBoxes boxes;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sing-along',
      theme: MetalTheme.themeData(),
      home: HomePage(boxes: boxes),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.boxes});

  final HiveBoxes boxes;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  PermissionStatus _permissionStatus = const PermissionStatus(
    notificationAccessGranted: false,
    overlayGranted: false,
  );
  bool _overlayActive = false;
  // Starts true since the app is always launched into the foreground; kept in sync with
  // AppLifecycleState.resumed (Navigator pushes within this same app, like the full-screen
  // lyrics page, never change this — only actually leaving the app does).
  bool _isAppVisible = true;
  // trackKey the currently-held lyrics/cache actually correspond to — lets a catch-up fetch
  // tell whether it's already up to date with what's playing before firing.
  String? _fetchedTrackKey;
  NowPlaying? _nowPlaying;
  late final NowPlayingWatcher _watcher;
  late final LyricsRepository _lyricsRepository = LyricsRepository(
    cacheBox: widget.boxes.lyrics,
  );
  StreamSubscription<NowPlaying?>? _positionSubscription;
  StreamSubscription<NowPlaying?>? _trackChangeSubscription;
  StreamSubscription<dynamic>? _overlayMessageSubscription;
  String _lyricsStatus = '';
  Map<String, dynamic>? _lastLyricsPayload;
  List<LyricsLine> _currentLyrics = const [];
  bool _currentLyricsIsUserPasted = false;
  // Manual override for a song whose LRC timestamps look right but feel wrong in practice (a
  // slightly-off match, odd LRCLIB timing, etc.) — set from the full-screen page's sync icon,
  // reset back to false whenever a genuinely new track starts fetching.
  bool _syncDisabledByUser = false;
  // Mirrors _syncDisabledByUser's role, but for the small overlay's/full-screen page's manual
  // +/-0.5s timing correction instead of the on/off toggle — same hub-and-spoke propagation
  // through this HomePage (neither the overlay nor the full-screen page can reach the other
  // directly), same per-track reset.
  int _syncOffsetMs = 0;
  bool _expandRequestInFlight = false;
  bool _toggleInFlight = false;
  Timer? _stopDebounceTimer;
  // trackKey of the most recently requested lyrics fetch — lets a fetch that's still running
  // when a newer track change starts recognize it's now stale once it finally completes.
  String? _latestRequestedTrackKey;
  bool _overlayPositionSendInFlight = false;
  final TextEditingController _songSearchController = TextEditingController();
  final FocusNode _songSearchFocusNode = FocusNode();
  final GlobalKey _songSearchFieldKey = GlobalKey();
  String _songSearchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watcher = NowPlayingWatcher();
    _overlayMessageSubscription = FlutterOverlayWindow.overlayListener.listen((
      event,
    ) {
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
        case 'syncOffset':
          _onOverlaySyncOffsetChanged(event);
      }
    });
    _positionSubscription = _watcher.positionStream.listen((event) {
      if (!mounted) return;
      setState(() => _nowPlaying = event);
      if (_overlayActive) _sendPositionToOverlay(event);
    });
    _trackChangeSubscription = _watcher.trackChanges.listen(_onTrackChanged);
    _refreshStatus();
    // The keyboard covers the bottom of the screen when the search field is focused, hiding
    // the results list right below it. Two things fix that together: collapsing the "현재 재생
    // 중" card and "가사 표시" button (below) frees up most of the space the keyboard would
    // otherwise eat into, and scrolling the field to the top of the viewport (instead of the
    // default "just barely visible" alignment) uses whatever room is left as efficiently as
    // possible. Note: whether the card/button actually collapse is driven by keyboard
    // visibility (MediaQuery.viewInsets.bottom in build()), not by focus — dismissing the
    // keyboard via the system back button/gesture hides the IME without clearing Flutter's
    // FocusNode.hasFocus, so a focus-driven collapse would get stuck collapsed forever with no
    // way to trigger it back open.
    _songSearchFocusNode.addListener(() {
      if (!_songSearchFocusNode.hasFocus) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final fieldContext = _songSearchFieldKey.currentContext;
        if (fieldContext == null) return;
        Scrollable.ensureVisible(
          fieldContext,
          alignment: 0.0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSubscription?.cancel();
    _trackChangeSubscription?.cancel();
    _overlayMessageSubscription?.cancel();
    _stopDebounceTimer?.cancel();
    _songSearchController.dispose();
    _songSearchFocusNode.dispose();
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
      _songSearchFocusNode.unfocus();
      if (mounted) {
        await Navigator.of(context).push(
          _fadeThroughRoute(
            FullScreenLyricsPage(
              watcher: _watcher,
              lyricsRepository: _lyricsRepository,
              initialNowPlaying: _nowPlaying,
              initialLines: _currentLyrics,
              initialIsUserPasted: _currentLyricsIsUserPasted,
              initialSyncDisabled: _syncDisabledByUser,
              initialSyncOffsetMs: _syncOffsetMs,
              onLyricsEdited: _applyLyricsResult,
              onSyncToggled: _setSyncDisabled,
              onSyncOffsetChanged: _setSyncOffset,
            ),
          ),
        );
        _songSearchFocusNode.unfocus();
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
        // A fetch for whatever was playing before this could still be in flight — make sure
        // its result gets dropped instead of landing after this "stopped" state and looking
        // like it's still playing.
        _latestRequestedTrackKey = null;
        if (!mounted) return;
        setState(() {
          _lyricsStatus = '';
          _currentLyrics = const [];
          _currentLyricsIsUserPasted = false;
        });
        _lastLyricsPayload = {
          'type': 'lyrics',
          'found': false,
          'title': '',
          'artist': '',
        };
        FlutterOverlayWindow.shareData(_lastLyricsPayload);
      });
      return;
    }
    _stopDebounceTimer?.cancel();
    // Neither the overlay nor the app's own screen is visible right now — there's nobody to
    // show a fetch to, so skip the API calls and Hive cache write entirely rather than
    // quietly accumulating data for songs the user never actually looked at. Whatever's
    // playing when the overlay/app becomes visible again gets caught up then (see
    // _catchUpLyricsIfNeeded), so nothing is permanently missed, just deferred.
    if (!_shouldFetchLyrics) return;
    await _fetchLyricsFor(nowPlaying);
  }

  bool get _shouldFetchLyrics => _overlayActive || _isAppVisible;

  Future<void> _fetchLyricsFor(NowPlaying nowPlaying) async {
    // Only ever called for a genuine track change (a fresh fetch, or a catch-up for a song
    // that isn't the one currently held) — never for the same song re-displaying, so this is
    // always the right place to drop a manual sync-off choice (and offset correction) that
    // belonged to the last song.
    _syncDisabledByUser = false;
    _syncOffsetMs = 0;
    if (mounted) setState(() => _lyricsStatus = '가사 검색 중...');
    // Marks this as the current track for as long as its fetch is running — if the song
    // changes again before it finishes (a fast skip, or several in a row), whichever fetch
    // completes will check this before doing anything, so a slower/earlier one that resolves
    // after a newer one has already landed can recognize it's stale instead of overwriting
    // the now-current song's lyrics with the one that used to be playing.
    final requestedTrackKey = nowPlaying.trackKey;
    _latestRequestedTrackKey = requestedTrackKey;
    // Sent immediately, before the (possibly several-second, for an uncached song) fetch
    // below even starts — otherwise the overlay/full-screen page just keep showing the
    // previous song's lines with nothing telling the user that's stale, right through the
    // window where it's most likely to be confusing.
    await FlutterOverlayWindow.shareData({
      'type': 'lyrics',
      'loading': true,
      'trackKey': nowPlaying.trackKey,
      'title': nowPlaying.title,
      'artist': nowPlaying.artist ?? '',
    });
    final result = await _lyricsRepository.getLyrics(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      durationSeconds: nowPlaying.durationMs > 0
          ? (nowPlaying.durationMs / 1000).round()
          : null,
    );
    if (_latestRequestedTrackKey != requestedTrackKey) {
      return; // superseded — drop this result
    }
    _fetchedTrackKey = requestedTrackKey;
    if (mounted) setState(() => _lyricsStatus = _statusFor(result));
    await _applyLyricsResult(nowPlaying, result);
  }

  // Called whenever the overlay or the app's own screen just became visible — if track
  // changes were being skipped while neither was up, this fetches for whatever's actually
  // playing right now instead of waiting for the *next* track change (which might be
  // minutes away, or never, if the same song keeps playing).
  Future<void> _catchUpLyricsIfNeeded() async {
    final current = _nowPlaying;
    if (current == null || current.trackKey == _fetchedTrackKey) return;
    await _fetchLyricsFor(current);
  }

  // Pushes a lyrics result out to both this screen's own state and the overlay — shared by a
  // normal track-change fetch and by the full-screen page editing the current song's lyrics
  // by hand (a paste-in, or discarding one back to the API result), so the small overlay
  // reflects that edit immediately instead of sitting on whatever it had before.
  Future<void> _applyLyricsResult(
    NowPlaying nowPlaying,
    LyricsResult result,
  ) async {
    // Also reached from the full-screen page's paste-in/refetch edits (not just a normal
    // fetch) — marking the track as up to date either way stops a later catch-up fetch from
    // clobbering a user's manual paste-in the next time the overlay/app becomes visible.
    _fetchedTrackKey = nowPlaying.trackKey;
    if (mounted) {
      setState(() {
        _currentLyrics = result.found ? result.lines : const [];
        _currentLyricsIsUserPasted = result.isUserPasted;
      });
    }
    if (result.found) await _recordRecentSong(nowPlaying);
    _lastLyricsPayload = {
      'type': 'lyrics',
      'found': result.found,
      'fromCache': result.fromCache,
      'isUserPasted': result.isUserPasted,
      'syncDisabled': _syncDisabledByUser,
      'syncOffsetMs': _syncOffsetMs,
      'trackKey': nowPlaying.trackKey,
      'title': nowPlaying.title,
      'artist': nowPlaying.artist ?? '',
      'durationMs': nowPlaying.durationMs,
      'lines': [
        for (final line in result.lines)
          {
            't': line.timestampMs,
            'o': line.original,
            'p': line.phonetic,
            'tr': line.translation,
          },
      ],
    };
    // shareData only reaches a listener that's alive *right now* — if the
    // overlay isn't open yet, this is lost, so _toggleOverlay() re-sends
    // this same cached payload once the overlay actually comes up.
    await FlutterOverlayWindow.shareData(_lastLyricsPayload);
  }

  // The "최근 들은 곡" section on the home screen only ever shows this many — but the box
  // itself keeps far more (see _recentSongsStorageCap below) so the title search field further
  // down can still find something played a while ago, not just the last handful of songs.
  static const int _recentSongsDisplayCount = 3;
  // A generous safety cap so the box doesn't grow forever over a long listening history —
  // not meant to be reached in normal use, unlike the old 4-item display cap this replaced.
  static const int _recentSongsStorageCap = 500;

  // Keyed by the same cache key the lyrics box uses, so replaying a song updates its
  // position in the list instead of adding a duplicate. Only title/artist are duplicated
  // here — the actual lines are looked up from the lyrics box by key when the user opens one.
  Future<void> _recordRecentSong(NowPlaying nowPlaying) async {
    final key = TitleNormalizer.cacheKey(
      nowPlaying.title,
      nowPlaying.artist ?? '',
    );
    await widget.boxes.recentSongs.put(
      key,
      RecentSongEntry(
        title: nowPlaying.title,
        artist: nowPlaying.artist ?? '',
        cacheKey: key,
        playedAt: DateTime.now(),
      ),
    );
    final box = widget.boxes.recentSongs;
    if (box.length > _recentSongsStorageCap) {
      final sortedKeys = box.keys.toList()
        ..sort((a, b) => box.get(b)!.playedAt.compareTo(box.get(a)!.playedAt));
      final staleKeys = sortedKeys.skip(_recentSongsStorageCap);
      await box.deleteAll(staleKeys);
    }
    if (mounted) {
      setState(() {}); // recent-songs/search sections read straight from the box
    }
  }

  List<RecentSongEntry> _recentSongsSorted() {
    final entries = widget.boxes.recentSongs.values.toList()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    return entries;
  }

  // Case-insensitive substring match on title (and artist, so searching "novelbright" finds
  // their songs too even if the query doesn't match any title) — across every song this device
  // has ever fetched lyrics for, not just the "최근 들은 곡" shortlist.
  List<RecentSongEntry> _searchRecentSongs(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return _recentSongsSorted()
        .where(
          (entry) =>
              entry.title.toLowerCase().contains(needle) ||
              entry.artist.toLowerCase().contains(needle),
        )
        .toList();
  }

  Future<void> _openSavedLyrics(RecentSongEntry entry) async {
    final result = _lyricsRepository.getCachedByKey(entry.cacheKey);
    if (!mounted || result == null) return;
    // Otherwise the search field (still focused from picking this result out of the results
    // list) regains focus on return and pops the keyboard straight back up over the home
    // screen — unfocus before leaving and again after returning covers both the outgoing
    // transition and Android restoring focus to it once this route is back on top.
    _songSearchFocusNode.unfocus();
    await Navigator.of(context).push(
      _fadeThroughRoute(
        SavedLyricsViewPage(
          title: entry.title,
          artist: entry.artist,
          lines: result.lines,
        ),
      ),
    );
    _songSearchFocusNode.unfocus();
  }

  // The full-screen page's sync icon is the only place this gets toggled — reversible any
  // number of times for the current song, propagated here so the small overlay (which has no
  // room for its own toggle) picks up the same choice.
  Future<void> _setSyncDisabled(bool disabled) async {
    if (_syncDisabledByUser == disabled) return;
    _syncDisabledByUser = disabled;
    final payload = _lastLyricsPayload;
    if (payload == null) return;
    _lastLyricsPayload = {...payload, 'syncDisabled': disabled};
    await FlutterOverlayWindow.shareData(_lastLyricsPayload);
  }

  // Called when the full-screen page's own +/- buttons change the offset — same propagation
  // as _setSyncDisabled above, so the small overlay (open or not right now) picks up the same
  // correction next time it renders.
  Future<void> _setSyncOffset(int offsetMs) async {
    if (_syncOffsetMs == offsetMs) return;
    _syncOffsetMs = offsetMs;
    final payload = _lastLyricsPayload;
    if (payload == null) return;
    _lastLyricsPayload = {...payload, 'syncOffsetMs': offsetMs};
    await FlutterOverlayWindow.shareData(_lastLyricsPayload);
  }

  // The mirror image of _setSyncOffset — the small overlay's own +/- buttons changed the
  // offset instead, relayed here (the overlay can't reach the full-screen page directly) so
  // that page picks up the same value the next time it's opened for this song. No need to
  // shareData anything back out: the overlay that sent this already has the value locally.
  void _onOverlaySyncOffsetChanged(Map event) {
    final offsetMs = event['offsetMs'] as int?;
    if (offsetMs == null) return;
    // Guards against a message for a song that's since been skipped past landing after the
    // fact and overwriting the new song's already-reset offset — same trackKey staleness
    // check _onPosition uses for the overlay's own position pings.
    if (event['trackKey'] != _nowPlaying?.trackKey) return;
    _syncOffsetMs = offsetMs;
    final payload = _lastLyricsPayload;
    if (payload != null) {
      _lastLyricsPayload = {...payload, 'syncOffsetMs': offsetMs};
    }
  }

  String _statusFor(LyricsResult result) {
    final cacheSuffix = result.fromCache ? ' (저장됨)' : '';
    if (!result.found) return '가사를 찾을 수 없음$cacheSuffix';
    final hasPhonetic = result.lines.any((line) => line.phonetic != null);
    final hasTranslation = result.lines.any((line) => line.translation != null);
    final tiers = [if (hasPhonetic) '독음', if (hasTranslation) '번역'];
    final tierLabel = tiers.isEmpty ? '원문만' : tiers.join(' · ');
    return '가사 로드됨 · $tierLabel$cacheSuffix';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasVisible = _isAppVisible;
    _isAppVisible = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      // Both permissions are granted through a system Settings screen, not a runtime
      // dialog, so re-check status whenever the user comes back to the app.
      _refreshStatus();
      if (!wasVisible) _catchUpLyricsIfNeeded();
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
      // showOverlay()'s `height` is consumed as raw physical pixels (unlike the plugin's
      // resizeOverlay(), which runs it through a dp->px conversion), so it has to be scaled by
      // the device's actual pixel ratio to land on a sane logical size. Sized as a share of
      // this device's own screen height (via _OverlayRootState.windowHeightScreenRatio — both
      // files are part of the same library) rather than a fixed dp number, so the overlay
      // takes up roughly the same proportion of the screen on a compact phone as it does on a
      // large one, instead of reading relatively bigger on a small screen and relatively tiny
      // on a big one. Read both before any `await` so neither is a stale BuildContext read.
      final mediaQuery = MediaQuery.of(context);
      final devicePixelRatio = mediaQuery.devicePixelRatio;
      final windowHeightDp =
          mediaQuery.size.height * _OverlayRootState.windowHeightScreenRatio;
      final overlayHeightPx = (windowHeightDp * devicePixelRatio).round();
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
        // note above for bottomCenter's failure mode. Offsetting y keeps the
        // native window's touchable rectangle entirely below the status
        // bar — sitting *behind* it (even if visually transparent there)
        // let the system status-bar gesture area intercept touches meant
        // for this card instead, including swallowing pinch/multi-touch
        // gestures near the top row's buttons. MediaQuery.padding.top read
        // from this context measured noticeably smaller than the real
        // status bar on-device — confirmed via dumpsys that this status
        // bar is 111px/~37dp tall, not the ~25dp the plugin's own
        // DEFAULT_STATUS_BAR_HEIGHT_DP fallback assumes either — so this
        // uses a fixed 40dp instead, clearing it with a small margin to
        // spare for devices with an even taller one (punch-hole cameras).
        startPosition: const OverlayPosition(0, 40),
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
      // The overlay just came up — if fetching had been paused while neither it nor the app
      // screen was visible, catch up on whatever's playing right now.
      await _catchUpLyricsIfNeeded();
    }
    await _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    // Same 360dp-reference ratio pattern the lyrics pages use, applied to this screen's own
    // hardcoded chrome sizes (icons, the wordmark, section headers) so they scale with the
    // actual screen instead of staying fixed dp/pt numbers on every device.
    final screenWidth = MediaQuery.of(context).size.width;
    const titleRatio = 0.0611; // 22/360
    const sectionIconRatio = 0.05; // 18/360
    const statusTextRatio = 0.0333; // 12/360
    // Driven by actual keyboard visibility rather than the search field's focus state — the
    // system back button/gesture hides the IME without clearing Flutter's focus, so a
    // focus-driven flag would get stuck collapsed with no way to bring the card/button back.
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.graphic_eq,
              size: screenWidth * titleRatio,
              color: MetalTheme.steelBright,
            ),
            const SizedBox(width: 8),
            // A flat title read plain against the same gradient every other screen already
            // has — a brushed-chrome shine across the letters (light -> bright -> light)
            // reads as a wordmark instead of a label, matching the rest of the metal look.
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [
                  MetalTheme.steelBright,
                  MetalTheme.textPrimary,
                  MetalTheme.steel,
                ],
                stops: [0.0, 0.55, 1.0],
              ).createShader(bounds),
              child: Text(
                'sing-along',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: screenWidth * titleRatio,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: MetalTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            // Extra bottom padding matching the keyboard's height, so there's always enough
            // scroll room to bring the search field (and the results just below it) above the
            // keyboard — without this, a short results list can't be scrolled far enough
            // because the content simply runs out before the field reaches the top.
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(context).viewInsets.bottom,
            ),
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
                // Tighter when the permission section above is already collapsed to its
                // compact granted-row form (the common case) than when it's still showing full
                // cards.
                SizedBox(height: _permissionStatus.allGranted ? 12 : 24),
                // Collapsed while the search field is focused — the keyboard eats roughly half
                // the screen at that point, and this is by far the biggest reclaimable chunk of
                // space, leaving much more room for the results list to actually show above it.
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: keyboardOpen
                      ? const SizedBox(width: double.infinity)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            MetalCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.graphic_eq,
                                        size: screenWidth * sectionIconRatio,
                                        color: MetalTheme.steel,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '현재 재생 중',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(letterSpacing: 0.3),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  if (_nowPlaying == null)
                                    const Text(
                                      '감지된 곡이 없습니다 — 다른 앱에서 음악을 재생해보세요',
                                      style: TextStyle(
                                        color: MetalTheme.textSecondary,
                                      ),
                                    )
                                  else ...[
                                    Text(
                                      _nowPlaying!.title,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    Text(
                                      _nowPlaying!.artist ?? '',
                                      style: const TextStyle(
                                        color: MetalTheme.textSecondary,
                                      ),
                                    ),
                                    Text(
                                      '${(_nowPlaying!.positionMs / 1000).toStringAsFixed(0)}s / '
                                      '${(_nowPlaying!.durationMs / 1000).toStringAsFixed(0)}s',
                                      style: const TextStyle(
                                        color: MetalTheme.textMuted,
                                      ),
                                    ),
                                    if (_lyricsStatus.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        _lyricsStatus,
                                        style: TextStyle(
                                          color: MetalTheme.steelBright,
                                          fontSize:
                                              screenWidth * statusTextRatio,
                                        ),
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            if (_permissionStatus.overlayGranted)
                              MetalButton(
                                icon: _overlayActive
                                    ? Icons.close
                                    : Icons.lyrics_outlined,
                                label: _overlayActive ? '가사 닫기' : '가사 표시',
                                onPressed: _toggleInFlight
                                    ? null
                                    : _toggleOverlay,
                              ),
                            const SizedBox(height: 20),
                          ],
                        ),
                ),
                const SizedBox(height: 12),
                _buildSongSearchField(context),
                const SizedBox(height: 10),
                Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: widget.boxes.recentSongs.isEmpty
                        ? null
                        : () => Navigator.of(context).push(
                              _fadeThroughRoute(
                                SavedSongsListPage(
                                  songs: _recentSongsSorted(),
                                  onOpen: _openSavedLyrics,
                                ),
                              ),
                            ),
                    // At least a 48dp-tall tap target (Android's own minimum touch target
                    // guideline) — the plain underlined text this replaced measured barely
                    // more than the text glyphs themselves, too small and fiddly to tap
                    // reliably.
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 4,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: MetalTheme.edgeHighlight,
                          width: 0.6,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.library_music_outlined,
                            color: MetalTheme.steel,
                            size: screenWidth * sectionIconRatio,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '총 ${widget.boxes.recentSongs.length}곡 저장됨',
                              style: TextStyle(
                                color: MetalTheme.textSecondary,
                                fontSize: screenWidth * statusTextRatio * 1.15,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: MetalTheme.steel,
                            size: screenWidth * sectionIconRatio,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_songSearchQuery.trim().isNotEmpty)
                  ..._buildSearchResultsSection(context)
                else
                  ..._buildRecentSongsSection(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Hidden entirely until there's at least one song to show — an empty "최근 들은 곡" card on
  // first run would just be clutter with nothing useful in it.
  List<Widget> _buildRecentSongsSection(BuildContext context) {
    final recent = _recentSongsSorted().take(_recentSongsDisplayCount).toList();
    if (recent.isEmpty) return const [];
    return [
      const SizedBox(height: 24),
      Row(
        children: [
          Icon(
            Icons.history,
            size: MediaQuery.of(context).size.width * 0.05,
            color: MetalTheme.steel,
          ),
          const SizedBox(width: 8),
          Text(
            '최근 들은 곡',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(letterSpacing: 0.3),
          ),
        ],
      ),
      const SizedBox(height: 8),
      MetalCard(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in recent)
              ListTile(
                title: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: entry.artist.isEmpty
                    ? null
                    : Text(
                        entry.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: MetalTheme.textSecondary),
                      ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: MetalTheme.steel,
                ),
                onTap: () => _openSavedLyrics(entry),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _buildSongSearchField(BuildContext context) {
    // Same 360dp-reference ratio pattern the rest of this screen uses (icons, wordmark,
    // section headers), applied here so the search field's text and icons scale with the
    // actual screen instead of staying fixed dp/pt sizes on every device.
    final screenWidth = MediaQuery.of(context).size.width;
    const textRatio = 0.0444; // 16/360
    const iconRatio = 0.05; // 18/360
    return TextField(
      key: _songSearchFieldKey,
      controller: _songSearchController,
      focusNode: _songSearchFocusNode,
      onChanged: (value) => setState(() => _songSearchQuery = value),
      style: TextStyle(color: Colors.white, fontSize: screenWidth * textRatio),
      decoration: InputDecoration(
        hintText: '곡 제목이나 가수로 저장된 가사 검색',
        hintStyle: TextStyle(
          color: MetalTheme.textMuted,
          fontSize: screenWidth * textRatio,
        ),
        // The close button takes over this left slot whenever the keyboard is up, not just
        // once there's text — otherwise a tap that focuses the field but hasn't typed
        // anything yet leaves no way to back out short of the system back button/gesture,
        // which the keyboard can make awkward to reach depending on the device's navigation
        // mode. Driven by keyboard visibility rather than the field's own focus state for the
        // same reason the card-collapse above is: the system back button/gesture can hide the
        // IME without clearing Flutter's focus, which would otherwise leave this stuck
        // visible forever.
        prefixIcon:
            (_songSearchQuery.isEmpty &&
                MediaQuery.of(context).viewInsets.bottom == 0)
            ? Icon(
                Icons.search,
                color: MetalTheme.steel,
                size: screenWidth * iconRatio,
              )
            : IconButton(
                icon: Icon(
                  Icons.close,
                  color: MetalTheme.textMuted,
                  size: screenWidth * iconRatio,
                ),
                onPressed: () {
                  _songSearchController.clear();
                  _songSearchFocusNode.unfocus();
                  setState(() => _songSearchQuery = '');
                },
              ),
        filled: true,
        fillColor: MetalTheme.surfaceDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: MetalTheme.edgeHighlight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: MetalTheme.edgeHighlight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MetalTheme.steelBright),
        ),
      ),
    );
  }

  // Shown in place of "최근 들은 곡" whenever the search field has text — searches across the
  // full saved-song index (not just the 4 most recently played) by title/artist substring.
  List<Widget> _buildSearchResultsSection(BuildContext context) {
    final results = _searchRecentSongs(_songSearchQuery);
    return [
      const SizedBox(height: 24),
      Row(
        children: [
          Icon(
            Icons.search,
            size: MediaQuery.of(context).size.width * 0.05,
            color: MetalTheme.steel,
          ),
          const SizedBox(width: 8),
          Text(
            '검색 결과',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(letterSpacing: 0.3),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (results.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '일치하는 저장된 가사가 없습니다',
            style: TextStyle(color: MetalTheme.textSecondary),
          ),
        )
      else
        MetalCard(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in results)
                ListTile(
                  title: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: entry.artist.isEmpty
                      ? null
                      : Text(
                          entry.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: MetalTheme.textSecondary,
                          ),
                        ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: MetalTheme.steel,
                  ),
                  onTap: () => _openSavedLyrics(entry),
                ),
            ],
          ),
        ),
    ];
  }
}

// A gentle cross-fade + scale instead of the default MaterialPageRoute slide-from-right —
// the overlay and the full-screen page are separate Android windows (a system overlay vs.
// this Activity), so there's no way to visually morph one into the other, but a fade reads
// as a much softer handoff than a sharp directional slide. Navigator animates this the same
// way in reverse on pop, so going back to the compact overlay gets the same treatment.
PageRoute<T> _fadeThroughRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}
