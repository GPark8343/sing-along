import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/platform/notification_bridge.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../../song_detection/now_playing_model.dart';
import '../../song_detection/now_playing_watcher.dart';
import '../theme/metal_theme.dart';

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
    this.initialIsUserPasted = false,
    this.initialSyncDisabled = false,
    this.initialSyncOffsetMs = 0,
    this.onLyricsEdited,
    this.onSyncToggled,
    this.onSyncOffsetChanged,
  });

  final NowPlayingWatcher watcher;
  final LyricsRepository lyricsRepository;
  final NowPlaying? initialNowPlaying;
  final List<LyricsLine> initialLines;
  final bool initialIsUserPasted;
  final bool initialSyncDisabled;
  // Whatever the small overlay's own +/- buttons last left this song's timing correction at
  // (0 if never touched, or if this is a fresh track) — main.dart is the only thing both this
  // page and the overlay can reach, so this is how a correction made in one carries over to
  // the other.
  final int initialSyncOffsetMs;
  // Called after a paste-in or a refetch-from-API succeeds, so the main engine (and, through
  // it, the small overlay — this page can't reach the overlay directly, only the main engine's
  // own shareData channel can) picks up the edit immediately instead of sitting on whatever it
  // had before until the next natural track change.
  final Future<void> Function(NowPlaying nowPlaying, LyricsResult result)?
  onLyricsEdited;
  // Called when the user taps the sync icon to turn synced auto-scroll off (a match that
  // looks right but feels off in practice) or back on — same propagation reason as above.
  final Future<void> Function(bool disabled)? onSyncToggled;
  // Called whenever the +/- buttons change the offset — same propagation reason as above, so
  // the small overlay picks up the same correction rather than each tracking its own.
  final Future<void> Function(int offsetMs)? onSyncOffsetChanged;

  @override
  State<FullScreenLyricsPage> createState() => _FullScreenLyricsPageState();
}

class _FullScreenLyricsPageState extends State<FullScreenLyricsPage>
    with WidgetsBindingObserver {
  final ItemScrollController _scrollController = ItemScrollController();
  final TextEditingController _pasteController = TextEditingController();
  late List<LyricsLine> _lines;
  NowPlaying? _nowPlaying;
  late String? _currentTrackKey;
  int _currentIndex = 0;
  bool _loadingLyrics = false;
  bool _savingPastedLyrics = false;
  bool _showPasteForm =
      false; // opened either automatically (not-found) or manually (wrong lyrics)
  bool _isUserPasted = false;
  bool _refetchingFromApi = false;
  bool _syncManuallyDisabled = false;
  // A manual correction for a synced song whose LRC timing doesn't quite line up with what's
  // actually playing — added to the real position before comparing against each line's
  // timestamp, so a positive value makes lines advance *earlier* (use this when the lyrics are
  // lagging behind the audio) and a negative one delays them (use this when lines are
  // appearing too early). Mirrors the small overlay's own offset control — kept as separate
  // state rather than shared, since the overlay engine and this one are different Flutter
  // engines with no shared Dart memory (see main.dart's part-of note). Resets on a track
  // change, same as the overlay's.
  int _syncOffsetMs = 0;
  // True only while the user's finger is actually on the list (set/cleared by a
  // NotificationListener<ScrollNotification> below, keyed off a real drag gesture — never by
  // our own programmatic scrollTo, so this can't self-trigger). A line change that lands
  // mid-drag just updates the highlight and leaves the view alone; the first one that lands
  // *after* they let go — whenever that naturally happens — is what re-centers it.
  bool _userDragging = false;
  StreamSubscription<NowPlaying?>? _positionSub;
  StreamSubscription<NowPlaying?>? _trackChangeSub;

  bool get _hasSyncData =>
      _lines.isNotEmpty && _lines.first.timestampMs != null;
  bool get _isSynced => _hasSyncData && !_syncManuallyDisabled;

  // Mirrors exactly which icons the AppBar's `actions` below actually renders, so the title
  // marquee's width calculation (which can't rely on AppBar handing it a bounded constraint
  // — see _MarqueeText's own comment) stays accurate instead of assuming a fixed icon count.
  int get _appBarActionCount {
    if (_lines.isEmpty || _showPasteForm) return 0;
    return 2 +
        (_isUserPasted
            ? 1
            : 0); // sync/tooltip + edit, plus refresh when pasted
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lines = widget.initialLines;
    _nowPlaying = widget.initialNowPlaying;
    _currentTrackKey = widget.initialNowPlaying?.trackKey;
    _isUserPasted = widget.initialIsUserPasted;
    _syncManuallyDisabled = widget.initialSyncDisabled;
    _syncOffsetMs = widget.initialSyncOffsetMs;
    _positionSub = widget.watcher.positionStream.listen(_onPosition);
    _trackChangeSub = widget.watcher.trackChanges.listen(_onTrackChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A real finger-drag always ends with a clean ScrollEndNotification, but if the app gets
    // backgrounded mid-drag (a call comes in, the user hits home, ...) the gesture can be torn
    // down without one ever firing — leaving _userDragging stuck true and auto-recentering
    // permanently stuck off for the rest of this song. Coming back to the foreground is a safe
    // point to assume any drag that was happening is definitely over.
    if (state == AppLifecycleState.resumed) {
      _userDragging = false;
    }
  }

  // Reversible any number of times for as long as this song keeps playing — the next genuine
  // track change (see _onTrackChanged) resets it back to synced-by-default.
  Future<void> _toggleSync() async {
    final nowPlaying = _nowPlaying ?? widget.initialNowPlaying;
    setState(() => _syncManuallyDisabled = !_syncManuallyDisabled);
    if (nowPlaying != null) {
      await widget.onSyncToggled?.call(_syncManuallyDisabled);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _trackChangeSub?.cancel();
    _pasteController.dispose();
    super.dispose();
  }

  // LRCLIB either doesn't have this song or (rarely, despite the matching safeguards) matched
  // the wrong one — this lets the user paste in lyrics they found themselves as a fallback,
  // going through the same on-device phonetic/translation pipeline a real fetch would and
  // landing in the same cache slot, so it displays and persists exactly like a normal result
  // (just unsynced, since pasted text carries no LRC timing).
  Future<void> _savePastedLyrics() async {
    final text = _pasteController.text;
    final nowPlaying = _nowPlaying ?? widget.initialNowPlaying;
    if (text.trim().isEmpty || nowPlaying == null || _savingPastedLyrics) {
      return;
    }
    setState(() => _savingPastedLyrics = true);
    final result = await widget.lyricsRepository.savePastedLyrics(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      pastedText: text,
    );
    if (!mounted) return;
    setState(() {
      _savingPastedLyrics = false;
      _lines = result.found ? result.lines : const [];
      _isUserPasted = result.isUserPasted;
      _currentIndex = 0;
      if (result.found) {
        _pasteController.clear();
        _showPasteForm = false;
      }
    });
    await widget.onLyricsEdited?.call(nowPlaying, result);
  }

  // A safety net for a paste-in that turns out to have been the wrong call — this discards it
  // and asks LRCLIB again, exactly as if the song had just started playing fresh.
  Future<void> _refetchOriginalFromApi() async {
    final nowPlaying = _nowPlaying ?? widget.initialNowPlaying;
    if (nowPlaying == null || _refetchingFromApi) return;
    setState(() {
      _refetchingFromApi = true;
      _loadingLyrics = true;
    });
    final result = await widget.lyricsRepository.refetchFromApi(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      durationSeconds: nowPlaying.durationMs > 0
          ? (nowPlaying.durationMs / 1000).round()
          : null,
    );
    if (!mounted) return;
    setState(() {
      _refetchingFromApi = false;
      _loadingLyrics = false;
      _lines = result.found ? result.lines : const [];
      _isUserPasted = result.isUserPasted;
      _currentIndex = 0;
    });
    await widget.onLyricsEdited?.call(nowPlaying, result);
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
    if (mounted) {
      setState(() {
        _nowPlaying = nowPlaying;
        _loadingLyrics = true;
        _lines = const [];
        _showPasteForm =
            false; // a paste form left open for the previous song is stale here
        _pasteController.clear();
        _syncManuallyDisabled =
            false; // a sync-off choice belonged to the last song, not this one
        _syncOffsetMs = 0; // ditto for a timing correction
      });
    }
    final result = await widget.lyricsRepository.getLyrics(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      durationSeconds: nowPlaying.durationMs > 0
          ? (nowPlaying.durationMs / 1000).round()
          : null,
    );
    // Another track change (a fast skip, or several) may have landed while this fetch was
    // still running — _currentTrackKey would have moved on by now, so this result is for a
    // song that isn't playing anymore and shouldn't overwrite what's currently shown.
    if (_currentTrackKey != nowPlaying.trackKey) return;
    if (!mounted) return;
    setState(() {
      _loadingLyrics = false;
      _lines = result.found ? result.lines : const [];
      _isUserPasted = result.isUserPasted;
      _currentIndex = 0;
    });
  }

  void _onPosition(NowPlaying? nowPlaying) {
    if (nowPlaying == null || _lines.isEmpty || !_isSynced) return;
    _nowPlaying = nowPlaying;
    _updateCurrentIndexForPosition(nowPlaying.positionMs);
  }

  void _updateCurrentIndexForPosition(int rawPositionMs) {
    final adjustedPositionMs = rawPositionMs + _syncOffsetMs;
    var index = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].timestampMs! <= adjustedPositionMs) {
        index = i;
      } else {
        break;
      }
    }
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    // The current line still updates/highlights normally either way — it's only the
    // programmatic re-centering that a drag defers, not the tracking itself. Checked live
    // (not a sticky flag) so the very next change after they let go — not the one still
    // in-flight when they did — is what resumes centering.
    if (_userDragging) return;
    if (_scrollController.isAttached) {
      _scrollController.scrollTo(
        index: index,
        alignment: 0.35,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // Unlike _onPosition (only called from a live position ping), this needs to force the
  // recompute even when the resulting index doesn't change — the offset itself is what the
  // user is trying to see feedback on, not just the current line.
  void _adjustSyncOffset(int deltaMs) {
    setState(() => _syncOffsetMs += deltaMs);
    final positionMs = _nowPlaying?.positionMs;
    if (positionMs != null) _updateCurrentIndexForPosition(positionMs);
    widget.onSyncOffsetChanged?.call(_syncOffsetMs);
  }

  String _titleAndArtist() {
    final nowPlaying = _nowPlaying ?? widget.initialNowPlaying;
    if (nowPlaying == null) return '가사';
    final artist = nowPlaying.artist;
    return (artist == null || artist.isEmpty)
        ? nowPlaying.title
        : '${nowPlaying.title} - $artist';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Let the pop happen normally first — main.dart's _onExpandRequested() is awaiting
      // this route's pop to restore the compact overlay, so blocking it here would leave
      // that cleanup stuck waiting forever. moveTaskToBack() alongside it is what actually
      // sends the user back to whatever app (e.g. YouTube Music) was in front before
      // bringToFront() surfaced this one — a plain pop alone would only reveal this app's
      // own HomePage underneath, since this route lives in the same Activity/Navigator.
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        NotificationBridge.moveTaskToBack();
      },
      child: Scaffold(
        backgroundColor: MetalTheme.base,
        appBar: AppBar(
          backgroundColor: MetalTheme.base,
          foregroundColor: Colors.white,
          elevation: 0,
          title: _MarqueeText(
            text: _titleAndArtist(),
            // Same 360dp-reference ratio pattern as _LyricRow (18/360).
            style: TextStyle(
              color: Colors.white,
              fontSize: MediaQuery.of(context).size.width * 0.05,
            ),
            // Was a flat magic number sized for exactly 2 action icons — stopped matching
            // reality (clipping the right edge of long titles) once a 3rd (refresh) icon could
            // show up too. Counting whatever's actually in `actions` below keeps this accurate
            // regardless of how many end up there. 56 ~= the back button, 48 per icon button,
            // 20 ~= AppBar's own title padding.
            reservedWidth: 56 + _appBarActionCount * 48 + 20,
          ),
          actions: [
            if (_lines.isNotEmpty && !_showPasteForm) ...[
              if (_hasSyncData)
                // Real sync data exists for this song — tappable, so a match that looks right
                // but feels off in practice (an odd LRCLIB timing offset, etc.) can be turned
                // off, and back on again, any number of times.
                IconButton(
                  tooltip: _isSynced
                      ? '싱크됨 — 자동으로 넘어감 (탭하면 끄기)'
                      : '싱크 꺼짐(수동) — 탭하면 다시 켜기',
                  icon: Icon(
                    _isSynced ? Icons.sync : Icons.sync_disabled,
                    color: _isSynced
                        ? Colors.lightGreenAccent
                        : Colors.orangeAccent,
                  ),
                  onPressed: _toggleSync,
                )
              else
                // No sync data at all for this song (unsynced fetch, or a paste-in) — nothing to
                // toggle, so this is just a plain indicator like before.
                const Tooltip(
                  message: '싱크 없음 — 직접 스크롤해서 보세요',
                  child: Icon(Icons.sync_disabled, color: Colors.orangeAccent),
                ),
              IconButton(
                tooltip: '가사가 틀렸나요? 직접 입력',
                icon: const Icon(Icons.edit_note, color: Colors.white70),
                onPressed: () => setState(() => _showPasteForm = true),
              ),
              if (_isUserPasted)
                IconButton(
                  tooltip: '직접 입력한 가사를 버리고 원본을 다시 불러오기',
                  icon: _refetchingFromApi
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        )
                      : const Icon(Icons.refresh, color: Colors.white70),
                  onPressed: _refetchingFromApi
                      ? null
                      : _refetchOriginalFromApi,
                ),
            ],
          ],
        ),
        // The AppBar already accounts for the top inset, so only the bottom (system navigation
        // bar) needs guarding here.
        body: Container(
          decoration: const BoxDecoration(
            gradient: MetalTheme.backgroundGradient,
          ),
          child: SafeArea(
            top: false,
            child: _loadingLyrics
                ? const Center(
                    child: Text(
                      '가사 불러오는 중...',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : (_lines.isEmpty || _showPasteForm)
                ? _PasteLyricsForm(
                    controller: _pasteController,
                    saving: _savingPastedLyrics,
                    onSave: _savePastedLyrics,
                    // Only offer a way out without saving when there's something to go back
                    // to — the auto-opened not-found form has nothing behind it to cancel to.
                    onCancel: _lines.isNotEmpty
                        ? () => setState(() => _showPasteForm = false)
                        : null,
                  )
                : Column(
                    children: [
                      // Sitting right above the lyrics themselves (not in the AppBar) so it
                      // doesn't eat into the title marquee's already-tight width — a long
                      // title+artist string was getting clipped noticeably once this and the
                      // sync/edit/refresh icons all had to share the AppBar with it. Only
                      // meaningful while actually auto-advancing — there's no "timing" to
                      // correct for a manually-scrolled or sync-disabled song. Mirrors the
                      // small overlay's own offset control (see overlay_main.dart's
                      // _SyncOffsetButton) — separate state since the two run in different
                      // Flutter engines with no shared Dart memory.
                      if (_isSynced) _SyncOffsetBar(
                        offsetMs: _syncOffsetMs,
                        onAdjust: _adjustSyncOffset,
                      ),
                      Expanded(
                        child: NotificationListener<ScrollNotification>(
                          // dragDetails is only non-null for a real finger-driven drag — our
                          // own scrollTo() below animates the list too and fires these same
                          // notifications, but never with dragDetails, so this can't mistake
                          // its own programmatic scroll for the user grabbing the list.
                          onNotification: (notification) {
                            if (notification is ScrollStartNotification &&
                                notification.dragDetails != null) {
                              _userDragging = true;
                            } else if (notification is ScrollEndNotification) {
                              _userDragging = false;
                            }
                            return false;
                          },
                          child: ScrollablePositionedList.builder(
                            itemScrollController: _scrollController,
                            itemCount: _lines.length,
                            // Bottom kept generous (same 360x800dp reference frame
                            // _LyricRow's font ratios use) so the last line can still center
                            // comfortably once it becomes current, same as before. Top
                            // shrunk down — it used to match the bottom, but once the sync
                            // offset bar (or nothing, when unsynced) already sits right above
                            // this list, that much *extra* empty space before the first line
                            // besides was just a big gap for no reason.
                            padding: EdgeInsets.fromLTRB(
                              MediaQuery.of(context).size.width * 0.0667,
                              MediaQuery.of(context).size.height * 0.04,
                              MediaQuery.of(context).size.width * 0.0667,
                              MediaQuery.of(context).size.height * 0.175,
                            ),
                            // Without sync data _currentIndex isn't tracking playback at all
                            // — it's just wherever it last happened to be (usually 0) — so
                            // highlighting it as "current" would be highlighting a
                            // meaningless line rather than the one actually being sung.
                            itemBuilder: (context, index) => _LyricRow(
                              line: _lines[index],
                              isCurrent: _isSynced && index == _currentIndex,
                            ),
                          ),
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

class _PasteLyricsForm extends StatelessWidget {
  const _PasteLyricsForm({
    required this.controller,
    required this.saving,
    required this.onSave,
    this.onCancel,
  });

  final TextEditingController controller;
  final bool saving;
  final VoidCallback onSave;
  // Present only when there's an existing (if wrong) result behind this form to go back to
  // without saving — null for the auto-opened not-found case, where there's nothing to cancel to.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            onCancel != null ? '가사가 잘못됐나요?' : '가사를 찾을 수 없음',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            '웹에서 찾은 가사를 붙여넣으면 이 곡에 저장돼요 (줄바꿈 기준으로 한 줄씩) — 싱크 정보 없이 원문으로만 저장됩니다',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: controller,
            maxLines: 10,
            minLines: 6,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '가사를 여기에 붙여넣으세요',
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: MetalTheme.surfaceDark,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: MetalTheme.edgeHighlight,
                  width: 0.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          MetalButton(
            label: saving ? '저장 중...' : '저장',
            icon: Icons.save_outlined,
            onPressed: saving ? null : onSave,
          ),
          if (onCancel != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: saving ? null : onCancel,
              child: const Text('취소', style: TextStyle(color: Colors.white54)),
            ),
          ],
        ],
      ),
    );
  }
}

/// A manual +/-0.5s correction for a synced song's timing, shown as its own bar above the
/// lyrics list rather than crammed into the AppBar — see the build() call site for why.
class _SyncOffsetBar extends StatelessWidget {
  const _SyncOffsetBar({required this.offsetMs, required this.onAdjust});

  final int offsetMs;
  final void Function(int deltaMs) onAdjust;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '가사를 조금 늦게 (-0.5초)',
            icon: const Icon(Icons.remove, color: Colors.white70),
            onPressed: () => onAdjust(-500),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${offsetMs > 0 ? '+' : ''}${(offsetMs / 1000).toStringAsFixed(1)}s',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: '가사를 조금 빠르게 (+0.5초)',
            icon: const Icon(Icons.add, color: Colors.white70),
            onPressed: () => onAdjust(500),
          ),
        ],
      ),
    );
  }
}

class _LyricRow extends StatelessWidget {
  const _LyricRow({required this.line, required this.isCurrent});

  final LyricsLine line;
  final bool isCurrent;

  // Ratios of screen width, calibrated against a 360dp-wide reference device (a common
  // Android baseline) to land on the same point sizes this page already used — but now
  // scaling with the actual screen instead of staying fixed on a tablet or a compact phone.
  // 독음 carries the current line's emphasis, so it grows the most; the other two tiers still
  // grow a little so the current line reads clearly without competing with it for attention.
  static const double _originalFontRatio = 0.0417;
  static const double _originalFontRatioCurrent = 0.0500;
  static const double _phoneticFontRatio = 0.0361;
  static const double _phoneticFontRatioCurrent = 0.0472;
  static const double _translationFontRatio = 0.0500;
  static const double _translationFontRatioCurrent = 0.0528;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: screenHeight * 0.0175),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.original,
            style: TextStyle(
              color: Colors.white70,
              fontSize:
                  screenWidth *
                  (isCurrent ? _originalFontRatioCurrent : _originalFontRatio),
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          if (line.phonetic != null) ...[
            SizedBox(height: screenHeight * 0.0025),
            Text(
              line.phonetic!,
              style: TextStyle(
                color: Colors.white70,
                fontSize:
                    screenWidth *
                    (isCurrent
                        ? _phoneticFontRatioCurrent
                        : _phoneticFontRatio),
                fontStyle: FontStyle.italic,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
          if (line.translation != null) ...[
            SizedBox(height: screenHeight * 0.005),
            Text(
              line.translation!,
              style: TextStyle(
                color: Colors.white70,
                fontSize:
                    screenWidth *
                    (isCurrent
                        ? _translationFontRatioCurrent
                        : _translationFontRatio),
                fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single-line text that, if too long to fit its available width, slides left to reveal
/// the rest and then slides back to the start — otherwise renders as plain static text, since
/// a long title+artist string is common enough in the AppBar to be worth handling, but most
/// are short enough that animating them would just be motion for no reason.
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    required this.reservedWidth,
  });

  final String text;
  final TextStyle style;
  // How much of the screen width to net out for everything else in the AppBar (back button,
  // action icons, padding) — passed in by the caller since only it knows how many action
  // icons are actually showing right now.
  final double reservedWidth;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;

  // Holds at the start (readable), sweeps left to fully reveal the end (also readable, held
  // briefly), then jumps straight back to the start and sweeps left again — one direction
  // only, never backtracking, unlike AnimationController's built-in reverse ping-pong.
  static const double _holdStart = 0.12;
  static const double _holdEnd = 0.82;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _progress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(_holdStart, _holdEnd, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller
        ..reset()
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AppBar's title slot doesn't reliably hand LayoutBuilder a *bounded* width — it can come
    // through as infinite depending on how leading/actions lay out — which made the overflow
    // check below always read "fits" and fall back to a static, ellipsized Text no matter how
    // long the title actually was. Computing the available width ourselves from the screen
    // size (netting out however much room the caller says the rest of the AppBar needs right
    // now) sidesteps that instead of depending on it.
    final availableWidth =
        MediaQuery.of(context).size.width - widget.reservedWidth;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final overflow = (painter.width - availableWidth).clamp(
      0.0,
      double.infinity,
    );
    return SizedBox(
      width: availableWidth,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _progress,
          builder: (context, child) => Transform.translate(
            offset: Offset(-overflow * _progress.value, 0),
            child: child,
          ),
          child: Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
          ),
        ),
      ),
    );
  }
}
