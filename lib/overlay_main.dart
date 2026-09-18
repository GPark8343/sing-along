part of 'main.dart';

/// Entry point for the floating overlay window. Runs in a separate
/// Flutter engine/isolate from the main app — no Dart memory is shared,
/// so state must come through Hive (durable) or [FlutterOverlayWindow]
/// share-data messages (live pings), never through Dart globals.
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}

class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OverlayRoot(),
    );
  }
}

class _LyricLine {
  final int? timestampMs; // null when this song has no LRC sync data
  final String original;
  final String?
  phonetic; // Japanese songs only — computed on-device, no key needed
  final String? translation; // once a DeepL key is configured

  const _LyricLine({
    required this.timestampMs,
    required this.original,
    this.phonetic,
    this.translation,
  });
}

class OverlayRoot extends StatefulWidget {
  const OverlayRoot({super.key});

  @override
  State<OverlayRoot> createState() => _OverlayRootState();
}

class _OverlayRootState extends State<OverlayRoot> {
  // A plain dp number is the same *physical* size on every device (that's what dp already
  // normalizes for), but not the same size *relative to the screen* — a phone with a small
  // display would end up with a proportionally huge card, a tablet with a proportionally
  // tiny one. windowHeightScreenRatio (read from main.dart, applied against that device's own
  // MediaQuery.size.height) fixes that by sizing the window as a share of the actual screen
  // instead of an absolute number. Everything below it is, in turn, a share of *that* window
  // (via the LayoutBuilder in build() below) rather than more absolute numbers — so however
  // tall the window ends up on a given device, the top bar/lyrics/progress row split it in
  // these exact proportions, always summing to the same total with nothing left over.
  static const double windowHeightScreenRatio = 0.29;
  static const double _topBarRatio = 0.30;
  static const double _lyricsAreaRatio = 0.55;
  static const double _progressRowRatio = 0.15;
  // Font sizes as a share of cardHeight too, for the same reason the layout above is ratio-
  // based — a plain pt number doesn't grow with a bigger card on a bigger screen, so short
  // lyrics (the ones FittedBox never needs to shrink) would read smaller than they should
  // relative to the card around them on a device with more room to work with.
  static const double _originalFontRatio = 0.116;
  static const double _phoneticFontRatio = 0.093;
  static const double _translationFontRatio = 0.087;
  static const double _placeholderFontRatio = 0.082;

  StreamSubscription<dynamic>? _messageSubscription;
  List<_LyricLine> _lines = const [];
  int _currentIndex = 0;
  String? _trackKey;
  String? _title;
  String? _artist;
  int? _positionMs;
  int? _durationMs;
  bool _fromCache = false;
  bool _loadingLyrics = false;
  bool _isUserPasted = false;
  // Set from the full-screen page's sync toggle (this card has no room for its own control) —
  // when true, treated exactly like a song with no sync data at all: no auto-advance, manual
  // left/right tap navigation instead.
  bool _syncDisabledByUser = false;

  @override
  void initState() {
    super.initState();
    _messageSubscription = FlutterOverlayWindow.overlayListener.listen(
      _onMessage,
    );
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }

  void _onMessage(dynamic event) {
    if (!mounted || event is! Map) return;
    switch (event['type']) {
      case 'lyrics':
        _onLyrics(event);
      case 'position':
        _onPosition(event);
    }
  }

  void _onLyrics(Map event) {
    final newTrackKey = event['trackKey'] as String?;
    // Sent the instant a track change is detected, before the (possibly several-second)
    // lookup even starts — shows a loading state instead of leaving the previous song's
    // lines on screen with nothing indicating they're stale.
    if (event['loading'] == true) {
      setState(() {
        _loadingLyrics = true;
        _trackKey = newTrackKey;
        _title = event['title'] as String?;
        _artist = event['artist'] as String?;
        _lines = const [];
        _positionMs = null;
        _currentIndex = 0;
      });
      return;
    }
    // A now-playing hiccup (e.g. some apps briefly clear their MediaSession metadata while
    // seeking) can make the main engine re-detect "the same song" as a track change, which
    // re-sends this same song's lyrics again. Treating that as a genuine new song would wipe
    // _positionMs/_currentIndex for no reason — right when a real position ping would
    // otherwise have kept things running smoothly — so only reset playback-tracking state
    // when this actually is a different song.
    final isGenuinelyNewTrack = newTrackKey != _trackKey;
    final found = event['found'] as bool? ?? false;
    final rawLines = event['lines'] as List<dynamic>? ?? const [];
    setState(() {
      _loadingLyrics = false;
      _trackKey = newTrackKey;
      _title = event['title'] as String?;
      _artist = event['artist'] as String?;
      _durationMs = event['durationMs'] as int?;
      _fromCache = event['fromCache'] as bool? ?? false;
      _isUserPasted = event['isUserPasted'] as bool? ?? false;
      _syncDisabledByUser = event['syncDisabled'] as bool? ?? false;
      _lines = found
          ? [
              for (final entry in rawLines)
                _LyricLine(
                  timestampMs: (entry as Map)['t'] as int?,
                  original: entry['o'] as String,
                  phonetic: entry['p'] as String?,
                  translation: entry['tr'] as String?,
                ),
            ]
          : const [];
      if (isGenuinelyNewTrack) {
        _positionMs = null;
        _currentIndex = 0;
      } else {
        _recomputeCurrentIndex();
      }
    });
  }

  void _onPosition(Map event) {
    // Ignore position pings meant for whatever song was playing before this
    // one — they'd otherwise briefly show the wrong current line.
    if (event['trackKey'] != _trackKey) return;
    setState(() {
      final rawPositionMs = event['positionMs'] as int?;
      _positionMs = rawPositionMs == null
          ? null
          : rawPositionMs + _relayDelayMs(event);
      _durationMs = (event['durationMs'] as int?) ?? _durationMs;
      _recomputeCurrentIndex();
    });
  }

  // How long this ping took to actually reach the overlay engine after the
  // main engine captured it — the two engines' Dart isolates run in the same
  // process, so DateTime.now() on both ends is directly comparable. Without
  // this, the overlay renders positionMs as if it were current the instant
  // it arrives, when it's really already however-long-the-shareData-hop-took
  // old — the gap that made lyrics visibly trail the audio.
  int _relayDelayMs(Map event) {
    final capturedAtMs = event['capturedAtMs'] as int?;
    if (capturedAtMs == null) return 0;
    final delay = DateTime.now().millisecondsSinceEpoch - capturedAtMs;
    return delay > 0 ? delay : 0; // guard against clock weirdness, never rewind
  }

  bool get _isSynced =>
      _lines.isNotEmpty &&
      _lines.first.timestampMs != null &&
      !_syncDisabledByUser;

  void _recomputeCurrentIndex() {
    if (!_isSynced || _positionMs == null) return;
    var index = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].timestampMs! <= _positionMs!) {
        index = i;
      } else {
        break;
      }
    }
    _currentIndex = index;
  }

  void _requestExpand() {
    FlutterOverlayWindow.shareData({'type': 'expand'});
  }

  // Closing from the overlay's own X button is invisible to the main engine's _overlayActive
  // state otherwise — it only finds out on its own next _refreshStatus() call (app resume,
  // permission screen return, ...), so the home screen's toggle button would keep reading
  // "오버레이 닫기" until then even though the overlay is already gone. Telling the main engine
  // directly keeps that button truthful immediately.
  void _requestClose() {
    FlutterOverlayWindow.shareData({'type': 'closed'});
    FlutterOverlayWindow.closeOverlay();
  }

  @override
  Widget build(BuildContext context) {
    // Anything that isn't actually synced — user-pasted text, a plain unsynced LRCLIB match,
    // or sync manually turned off from the full-screen page — has no reliable "current line"
    // to show here: this card has no room for manual left/right navigation UI, so it just
    // points the user at the full-screen page instead.
    final currentLine = (_lines.isEmpty || !_isSynced)
        ? null
        : _lines[_currentIndex.clamp(0, _lines.length - 1)];
    final progress =
        (_durationMs != null && _durationMs! > 0 && _positionMs != null)
        ? (_positionMs! / _durationMs!).clamp(0.0, 1.0)
        : 0.0;

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        // Align + a full-width SizedBox split the two axes: full window width (so the card
        // still spans edge to edge) but a fixed, content-independent height — every section
        // below (top bar, lyrics area, progress row) has a fixed height of its own now, so
        // the card's total height always matches the native window's, with no leftover
        // transparent gap between the card and the window's bottom edge.
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: SizedBox(
              width: double.infinity,
              // Reads however much height Align actually left after SafeArea/outer padding —
              // whatever that ends up being on this device, the three sections below split it
              // by ratio rather than by an absolute number, so the card always exactly fills
              // it with nothing left over.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cardHeight = constraints.maxHeight;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          // Comfortably above Android's 48dp minimum touch-target guidance at
                          // any normal window size — 32dp (the old icon-only visual size)
                          // measured out as too small to reliably hit on a small floating card.
                          height: cardHeight * _topBarRatio,
                          child: Row(
                            children: [
                              const SizedBox(width: 12),
                              if (_fromCache && _lines.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.bookmark,
                                  color: Colors.amberAccent,
                                  size: 14,
                                ),
                                const SizedBox(width: 2),
                                const Text(
                                  '저장됨',
                                  style: TextStyle(
                                    color: Colors.amberAccent,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                              if (_lines.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Tooltip(
                                  message: _isSynced
                                      ? '싱크됨 — 자동으로 넘어감'
                                      : '싱크 없음 — 눌러서 전체화면으로 보기',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _isSynced
                                            ? Icons.sync
                                            : Icons.sync_disabled,
                                        color: _isSynced
                                            ? Colors.lightGreenAccent
                                            : Colors.orangeAccent,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        _isSynced ? '동기화' : '비동기화',
                                        style: TextStyle(
                                          color: _isSynced
                                              ? Colors.lightGreenAccent
                                              : Colors.orangeAccent,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const Spacer(),
                              IconButton(
                                iconSize: 22,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 44,
                                  minHeight: 44,
                                ),
                                icon: const Icon(
                                  Icons.open_in_full,
                                  color: Colors.white70,
                                ),
                                // The overlay engine has no native channels of its own (see
                                // main.dart's part-of note) — shareData/overlayListener is the only
                                // way back to the main engine, which is what actually brings the
                                // app forward and pushes the full-screen route.
                                onPressed: _requestExpand,
                              ),
                              IconButton(
                                iconSize: 22,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 44,
                                  minHeight: 44,
                                ),
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white70,
                                ),
                                onPressed: _requestClose,
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                        ),
                        // Fixed, not capped — a shrink-to-content ConstrainedBox left a visible
                        // transparent gap between the card and the native window's bottom edge
                        // (the window itself is a constant size; only the card was shrinking) for
                        // any song whose lyrics were short enough not to need the full budget.
                        SizedBox(
                          height: cardHeight * _lyricsAreaRatio,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            child: LayoutBuilder(
                              builder: (context, constraints) => GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                // Nothing found, user-pasted text, or any other not-actually-
                                // synced lyrics all show the same "go look at the full screen"
                                // placeholder below — tapping anywhere opens it. Synced lyrics
                                // tap does nothing, since it already advances on its own.
                                onTapUp:
                                    !_loadingLyrics &&
                                        _trackKey != null &&
                                        currentLine == null
                                    ? (_) => _requestExpand()
                                    : null,
                                child: Center(
                                  // Rather than a fixed font size that either wraps to 2 lines
                                  // (clipped once all three tiers do it at once, per the
                                  // fixed-height box above) or scrolls (unreadable at a glance on
                                  // a card this size), every tier scales down together to
                                  // whatever fits this fixed box — a short line renders at full
                                  // size, a long one shrinks just enough, and nothing is ever cut
                                  // off no matter how much text a line has.
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: currentLine == null
                                        ? Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (_title != null &&
                                                  _title!.isNotEmpty) ...[
                                                Text(
                                                  (_artist == null ||
                                                          _artist!.isEmpty)
                                                      ? _title!
                                                      : '${_title!} - ${_artist!}',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    fontSize:
                                                        cardHeight *
                                                        _placeholderFontRatio *
                                                        1.15,
                                                  ),
                                                ),
                                                SizedBox(
                                                  height: cardHeight * 0.025,
                                                ),
                                              ],
                                              Text(
                                                _loadingLyrics
                                                    ? '가사 불러오는 중...'
                                                    : (_isUserPasted
                                                          ? '직접 입력한 가사 — 눌러서 전체화면으로 보기'
                                                          : (_lines
                                                                    .isNotEmpty
                                                                ? '싱크 없는 가사 — 눌러서 전체화면으로 보기'
                                                                : (_trackKey !=
                                                                          null
                                                                      ? '가사를 찾을 수 없음 — 눌러서 직접 입력'
                                                                      : '오버레이 준비됨 — 다른 앱에서 음악을 재생해보세요'))),
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: Colors.white70,
                                                  fontSize:
                                                      cardHeight *
                                                      _placeholderFontRatio,
                                                ),
                                              ),
                                            ],
                                          )
                                        : Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                currentLine.original,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize:
                                                      cardHeight *
                                                      _originalFontRatio,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              if (currentLine.phonetic !=
                                                  null) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  currentLine.phonetic!,
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: Colors.white70,
                                                    fontSize:
                                                        cardHeight *
                                                        _phoneticFontRatio,
                                                  ),
                                                ),
                                              ],
                                              if (currentLine.translation !=
                                                  null) ...[
                                                const SizedBox(height: 2),
                                                Text(
                                                  currentLine.translation!,
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: Colors.white54,
                                                    fontSize:
                                                        cardHeight *
                                                        _translationFontRatio,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: cardHeight * _progressRowRatio,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 2, 6, 4),
                            child: Row(
                              children: [
                                Text(
                                  _formatMs(_positionMs),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 4,
                                      backgroundColor: Colors.white24,
                                      valueColor: const AlwaysStoppedAnimation(
                                        Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _formatMs(_durationMs),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatMs(int? ms) {
    if (ms == null || ms < 0) return '--:--';
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
