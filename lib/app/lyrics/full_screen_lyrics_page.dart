import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../data/repositories/lyrics_repository.dart';
import '../../song_detection/now_playing_model.dart';
import '../../song_detection/now_playing_watcher.dart';

/// Full-screen lyrics view (YouTube-Music-style: a scrolling list of every line, current line
/// bold/bright, the rest dimmed) — opened from the floating overlay's expand button when the
/// small card isn't enough room. Independently subscribes to the same [NowPlayingWatcher]
/// streams HomePage does, so it keeps following the song (including a track change) on its own
/// rather than needing HomePage to keep relaying state into it.
class FullScreenLyricsPage extends StatefulWidget {
  const FullScreenLyricsPage({
    super.key,
    required this.watcher,
    required this.lyricsRepository,
    required this.initialNowPlaying,
    required this.initialLines,
  });

  final NowPlayingWatcher watcher;
  final LyricsRepository lyricsRepository;
  final NowPlaying? initialNowPlaying;
  final List<LyricsLine> initialLines;

  @override
  State<FullScreenLyricsPage> createState() => _FullScreenLyricsPageState();
}

class _FullScreenLyricsPageState extends State<FullScreenLyricsPage> {
  final ItemScrollController _scrollController = ItemScrollController();
  late List<LyricsLine> _lines;
  NowPlaying? _nowPlaying;
  late String? _currentTrackKey;
  int _currentIndex = 0;
  StreamSubscription<NowPlaying?>? _positionSub;
  StreamSubscription<NowPlaying?>? _trackChangeSub;

  @override
  void initState() {
    super.initState();
    _lines = widget.initialLines;
    _nowPlaying = widget.initialNowPlaying;
    _currentTrackKey = widget.initialNowPlaying?.trackKey;
    _positionSub = widget.watcher.positionStream.listen(_onPosition);
    _trackChangeSub = widget.watcher.trackChanges.listen(_onTrackChanged);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _trackChangeSub?.cancel();
    super.dispose();
  }

  Future<void> _onTrackChanged(NowPlaying? nowPlaying) async {
    // Compared against the *current* track, not the one this page originally opened with —
    // otherwise, after a genuine switch to a second song, a now-playing hiccup re-reporting
    // that same second song (some apps briefly clear their MediaSession metadata while
    // seeking) would look like yet another "new" track relative to the first, triggering a
    // pointless re-fetch and resetting _currentIndex for no reason.
    if (nowPlaying?.trackKey == _currentTrackKey) return;
    _currentTrackKey = nowPlaying?.trackKey;
    if (nowPlaying == null) {
      if (mounted) setState(() => _lines = const []);
      return;
    }
    if (mounted) setState(() => _nowPlaying = nowPlaying);
    final result = await widget.lyricsRepository.getLyrics(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      durationSeconds: nowPlaying.durationMs > 0 ? (nowPlaying.durationMs / 1000).round() : null,
    );
    if (!mounted) return;
    setState(() {
      _lines = result.found ? result.lines : const [];
      _currentIndex = 0;
    });
  }

  void _onPosition(NowPlaying? nowPlaying) {
    if (nowPlaying == null || _lines.isEmpty || _lines.first.timestampMs == null) return;
    _nowPlaying = nowPlaying;
    var index = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].timestampMs! <= nowPlaying.positionMs) {
        index = i;
      } else {
        break;
      }
    }
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    if (_scrollController.isAttached) {
      _scrollController.scrollTo(
        index: index,
        alignment: 0.35,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          _nowPlaying?.title ?? widget.initialNowPlaying?.title ?? '가사',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _lines.isEmpty
          ? const Center(
              child: Text('가사를 찾을 수 없음', style: TextStyle(color: Colors.white54)),
            )
          : ScrollablePositionedList.builder(
              itemScrollController: _scrollController,
              itemCount: _lines.length,
              padding: const EdgeInsets.symmetric(vertical: 140, horizontal: 24),
              itemBuilder: (context, index) => _LyricRow(
                line: _lines[index],
                isCurrent: index == _currentIndex,
              ),
            ),
    );
  }
}

class _LyricRow extends StatelessWidget {
  const _LyricRow({required this.line, required this.isCurrent});

  final LyricsLine line;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.original,
            style: TextStyle(
              color: isCurrent ? Colors.white54 : Colors.white24,
              fontSize: 15,
            ),
          ),
          if (line.phonetic != null) ...[
            const SizedBox(height: 2),
            Text(
              line.phonetic!,
              style: TextStyle(
                color: isCurrent ? Colors.white38 : Colors.white12,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (line.translation != null) ...[
            const SizedBox(height: 4),
            Text(
              line.translation!,
              style: TextStyle(
                color: isCurrent ? Colors.white : Colors.white30,
                fontSize: isCurrent ? 24 : 18,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
