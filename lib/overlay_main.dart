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
  final String? phonetic; // Japanese songs only — computed on-device, no key needed
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
  // Fixed to comfortably fit the common case — every tier (원문/독음/번역) two
  // lines deep — rather than either a single-line-tight budget (clips
  // often) or a many-line-generous one (a bigger dead zone below the card
  // blocks taps to whatever app is underneath; Android intercepts touches
  // for the window's entire rectangle, not just its opaque pixels). A
  // genuinely longer line still degrades gracefully via the scroll fallback
  // below instead of being clipped outright.
  static const double _maxCardHeight = 230;

  StreamSubscription<dynamic>? _messageSubscription;
  List<_LyricLine> _lines = const [];
  int _currentIndex = 0;
  String? _trackKey;
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
      _positionMs = rawPositionMs == null ? null : rawPositionMs + _relayDelayMs(event);
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
      _lines.isNotEmpty && _lines.first.timestampMs != null && !_syncDisabledByUser;

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

  void _advanceLine(int delta) {
    if (_isSynced || _lines.isEmpty) return;
    // Clamped, not wrapped — tapping left on the first line or right on the last does
    // nothing, rather than looping around to the other end, which reads as a bug ("why did
    // it jump to the end?") more than a feature.
    final next = (_currentIndex + delta).clamp(0, _lines.length - 1);
    if (next == _currentIndex) return;
    setState(() => _currentIndex = next);
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
    // User-pasted lyrics are never rendered in this small card — there's no room here to
    // offer the paste UI itself, so this just points the user at the full-screen page instead
    // of trying (and failing) to usefully cram hand-entered text into this space.
    final currentLine = (_lines.isEmpty || _isUserPasted)
        ? null
        : _lines[_currentIndex.clamp(0, _lines.length - 1)];
    final progress =
        (_durationMs != null && _durationMs! > 0 && _positionMs != null)
        ? (_positionMs! / _durationMs!).clamp(0.0, 1.0)
        : 0.0;

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        // Align + a full-width SizedBox split the two axes: full window
        // width (so the card still spans edge to edge) but only as much
        // height as the content actually needs (Align hands its child loose
        // constraints, so the mainAxisSize.min Column below isn't forced to
        // stretch to the window's full — fixed, oversized — height).
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: SizedBox(
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      // 44dp keeps both buttons close to Android's 48dp minimum comfortable
                      // touch-target guidance — 32dp (matching the old icon-only visual size)
                      // measured out as too small to reliably hit on a small floating card.
                      height: 44,
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.drag_handle,
                            color: Colors.white38,
                            size: 18,
                          ),
                          if (_fromCache && _lines.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.bolt,
                              color: Colors.amberAccent,
                              size: 14,
                            ),
                            const SizedBox(width: 2),
                            const Text(
                              '캐시',
                              style: TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                          ],
                          if (_lines.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Tooltip(
                              message: _isSynced
                                  ? '싱크됨 — 자동으로 넘어감'
                                  : '싱크 없음 — 좌우 탭으로 넘기세요',
                              child: Icon(
                                _isSynced ? Icons.sync : Icons.sync_disabled,
                                color: _isSynced ? Colors.lightGreenAccent : Colors.orangeAccent,
                                size: 14,
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
                    // Capped so one outlier line can't push the card past
                    // _maxCardHeight — beyond the cap it scrolls instead.
                    // 90 = the top bar (44) + progress bar row (~30) + the
                    // padding around both.
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: _maxCardHeight - 90,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) => GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            // Several different meanings depending on state: nothing found,
                            // or the user's own pasted lyrics (this card has no room to offer
                            // a paste UI, or to usefully show hand-entered text) — tapping
                            // opens the full-screen page either way. Plain (unsynced) fetched
                            // lyrics — tap the right half for the next line, left half for the
                            // previous one. Synced lyrics — tap does nothing, it already
                            // advances on its own.
                            onTapUp: !_loadingLyrics && _trackKey != null && (_lines.isEmpty || _isUserPasted)
                                ? (_) => _requestExpand()
                                : (_lines.isNotEmpty && !_isSynced && !_isUserPasted
                                    ? (details) => _advanceLine(
                                        details.localPosition.dx > constraints.maxWidth / 2
                                            ? 1
                                            : -1,
                                      )
                                    : null),
                            child: SingleChildScrollView(
                              child: Center(
                              child: currentLine == null
                                  ? Text(
                                      _loadingLyrics
                                          ? '가사 불러오는 중...'
                                          : (_isUserPasted
                                              ? '직접 입력한 가사 — 눌러서 전체화면으로 보기'
                                              : (_trackKey != null
                                                  ? '가사를 찾을 수 없음 — 눌러서 직접 입력'
                                                  : '오버레이 준비됨 — 다른 앱에서 음악을 재생해보세요')),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                      ),
                                    )
                                  : Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          currentLine.original,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (currentLine.phonetic != null) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            currentLine.phonetic!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                        if (currentLine.translation != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            currentLine.translation!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 13,
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 2, 6, 8),
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
                  ],
                ),
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
