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
  final String text;

  const _LyricLine(this.timestampMs, this.text);
}

class OverlayRoot extends StatefulWidget {
  const OverlayRoot({super.key});

  @override
  State<OverlayRoot> createState() => _OverlayRootState();
}

class _OverlayRootState extends State<OverlayRoot> {
  static final RegExp _lrcLine = RegExp(r'^\[(\d{2}):(\d{2})[.:](\d{2,3})\]\s*(.*)$');

  StreamSubscription<dynamic>? _messageSubscription;
  List<_LyricLine> _lines = const [];
  int _currentIndex = 0;
  String? _trackKey;
  int? _positionMs;
  int? _durationMs;
  int _offsetMs = 0;

  @override
  void initState() {
    super.initState();
    _messageSubscription = FlutterOverlayWindow.overlayListener.listen(_onMessage);
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
    final found = event['found'] as bool? ?? false;
    setState(() {
      _trackKey = event['trackKey'] as String?;
      _durationMs = event['durationMs'] as int?;
      _positionMs = null;
      _offsetMs = 0;
      _currentIndex = 0;
      _lines = found ? _parseLines(event['plainLyrics'] as String?, event['syncedLyrics'] as String?) : const [];
    });
  }

  void _onPosition(Map event) {
    // Ignore position pings meant for whatever song was playing before this
    // one — they'd otherwise briefly show the wrong current line.
    if (event['trackKey'] != _trackKey) return;
    setState(() {
      _positionMs = event['positionMs'] as int?;
      _durationMs = (event['durationMs'] as int?) ?? _durationMs;
      _recomputeCurrentIndex();
    });
  }

  List<_LyricLine> _parseLines(String? plain, String? synced) {
    if (synced != null && synced.trim().isNotEmpty) {
      final lines = <_LyricLine>[];
      for (final raw in synced.split('\n')) {
        final match = _lrcLine.firstMatch(raw);
        if (match == null) continue;
        final text = match.group(4)!.trim();
        if (text.isEmpty) continue;
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3)!;
        final millis = fraction.length == 2 ? int.parse(fraction) * 10 : int.parse(fraction);
        lines.add(_LyricLine(minutes * 60000 + seconds * 1000 + millis, text));
      }
      if (lines.isNotEmpty) return lines;
    }
    // Fallback tier: plain text only, no timestamps — current line advances
    // by tapping instead of tracking playback position.
    final plainText = plain ?? '';
    return plainText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => _LyricLine(null, line))
        .toList();
  }

  bool get _isSynced => _lines.isNotEmpty && _lines.first.timestampMs != null;

  void _recomputeCurrentIndex() {
    if (!_isSynced || _positionMs == null) return;
    final adjusted = _positionMs! + _offsetMs;
    var index = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].timestampMs! <= adjusted) {
        index = i;
      } else {
        break;
      }
    }
    _currentIndex = index;
  }

  void _adjustOffset(int deltaMs) {
    if (!_isSynced) return;
    setState(() {
      _offsetMs += deltaMs;
      _recomputeCurrentIndex();
    });
  }

  void _advanceManual() {
    if (_isSynced || _lines.isEmpty) return;
    setState(() => _currentIndex = (_currentIndex + 1) % _lines.length);
  }

  @override
  Widget build(BuildContext context) {
    final currentLine = _lines.isEmpty ? null : _lines[_currentIndex.clamp(0, _lines.length - 1)];
    final progress = (_durationMs != null && _durationMs! > 0 && _positionMs != null)
        ? (_positionMs! / _durationMs!).clamp(0.0, 1.0)
        : 0.0;

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      const Icon(Icons.drag_handle, color: Colors.white38, size: 18),
                      const Spacer(),
                      IconButton(
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => FlutterOverlayWindow.closeOverlay(),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _advanceManual,
                    child: currentLine == null
                        ? const Text(
                            '오버레이 준비됨 — 다른 앱에서 음악을 재생해보세요',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          )
                        : Text(
                            currentLine.text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 6, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation(Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _OffsetButton(label: '-1s', onTap: () => _adjustOffset(-1000)),
                      _OffsetButton(label: '+1s', onTap: () => _adjustOffset(1000)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OffsetButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _OffsetButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ),
    );
  }
}
