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

  // Checked across every line, not just the first — an otherwise-fully-timed LRCLIB submission
  // occasionally has an untimed leading line (a credit, an intro tag), which made this whole
  // song register as "no sync at all" and permanently disable the toggle even though every
  // other line genuinely had real timing.
  bool get _hasSyncData => _lines.any((line) => line.timestampMs != null);
  bool get _isSynced => _hasSyncData && !_syncManuallyDisabled;

  // Mirrors exactly which icons the AppBar's `actions` below actually renders, so the title
  // marquee's width calculation (which can't rely on AppBar handing it a bounded constraint
  // — see _MarqueeText's own comment) stays accurate instead of assuming a fixed icon count.
  int get _appBarActionCount {
    if (_lines.isEmpty) return 0;
    return 1 + // sync/tooltip icon, always shown
        (_showPasteForm ? 0 : 1) + // edit icon, hidden while already editing
        (_isUserPasted ? 1 : 0); // refresh icon, only for a paste-in
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
    super.dispose();
  }

  // Corrects one line's 독음/번역 in place — most commonly the on-device Kuromoji reading
  // getting a single word wrong, which doesn't warrant discarding the whole song's sync and
  // every other line's already-correct tiers the way the whole-song paste form would.
  Future<void> _editLine(int index) async {
    final nowPlaying = _nowPlaying ?? widget.initialNowPlaying;
    if (nowPlaying == null || index < 0 || index >= _lines.length) return;
    final line = _lines[index];
    final originalController = TextEditingController(text: line.original);
    final phoneticController = TextEditingController(text: line.phonetic ?? '');
    final translationController = TextEditingController(
      text: line.translation ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: MetalTheme.surfaceDark,
        title: const Text('가사 줄 수정', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Editable, not just shown for reference — a correction here still keeps the
              // line's timestamp untouched (see updateLine()), so sync isn't lost even when
              // the original text itself was the thing that needed fixing.
              TextField(
                controller: originalController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '원문',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneticController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '독음',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: translationController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '번역',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final result = await widget.lyricsRepository.updateLine(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      lineIndex: index,
      original: originalController.text,
      phonetic: phoneticController.text,
      translation: translationController.text,
    );
    if (result == null || !mounted) return;
    setState(() => _lines = result.lines);
    await widget.onLyricsEdited?.call(nowPlaying, result);
  }

  // LRCLIB either doesn't have this song or (rarely, despite the matching safeguards) matched
  // the wrong one — this lets the user paste in lyrics they found themselves as a fallback,
  // going through the same on-device phonetic/translation pipeline a real fetch would and
  // landing in the same cache slot, so it displays and persists exactly like a normal result
  // (just unsynced, since pasted text carries no LRC timing).
  Future<void> _savePastedLyrics(List<LyricsLine> lines) async {
    final nowPlaying = _nowPlaying ?? widget.initialNowPlaying;
    // Saving with every line emptied out is allowed on purpose — clearing the form and hitting
    // save is how this song gets marked back to "no lyrics" instead of being stuck showing
    // whatever was pasted in before.
    if (nowPlaying == null || _savingPastedLyrics) return;
    setState(() => _savingPastedLyrics = true);
    final result = await widget.lyricsRepository.savePastedLyrics(
      title: nowPlaying.title,
      artist: nowPlaying.artist ?? '',
      lines: lines,
    );
    if (!mounted) return;
    setState(() {
      _savingPastedLyrics = false;
      // Reflected on this same screen immediately — no extra round trip needed, since the
      // fresh result is already in hand here rather than waiting on onLyricsEdited below.
      _lines = result.found ? result.lines : const [];
      _isUserPasted = result.isUserPasted;
      _currentIndex = 0;
      _showPasteForm = false;
    });
    // Lands back on the full lyrics view at the top — the edit form (whichever layout it was
    // showing) is gone the instant _showPasteForm flips, but without this the list could still
    // be scrolled wherever it happened to be from before this song was even opened for editing.
    if (result.found && _scrollController.isAttached) {
      _scrollController.jumpTo(index: 0);
    }
    // Propagates to main.dart (and, through it, the small overlay) so neither is left showing
    // the stale pre-edit text until the next natural track change.
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
      // A line with no timestamp of its own (an untimed leading credit/tag — see
      // _hasSyncData) can't be compared against the position at all; skip it rather than
      // crash on the null, leaving index pointed at the last *timed* line at or before now.
      final timestampMs = _lines[i].timestampMs;
      if (timestampMs == null) continue;
      if (timestampMs <= adjustedPositionMs) {
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
      // While the edit form is open, back closes *that* and returns to this same page's
      // reading view — not the small overlay — the same as tapping 취소 would. Only when
      // there's no form to back out of does back actually leave the full-screen page: let the
      // pop happen normally first (main.dart's _onExpandRequested() is awaiting this route's
      // pop to restore the compact overlay, so blocking it here would leave that cleanup stuck
      // waiting forever), then moveTaskToBack() alongside it to actually send the user back to
      // whatever app (e.g. YouTube Music) was in front before bringToFront() surfaced this one
      // — a plain pop alone would only reveal this app's own HomePage underneath, since this
      // route lives in the same Activity/Navigator.
      canPop: !_showPasteForm,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          NotificationBridge.moveTaskToBack();
          return;
        }
        if (_showPasteForm) setState(() => _showPasteForm = false);
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
            if (_lines.isNotEmpty) ...[
              if (_hasSyncData)
                // Real sync data exists for this song — tappable, so a match that looks right
                // but feels off in practice (an odd LRCLIB timing offset, etc.) can be turned
                // off, and back on again, any number of times. Kept visible even while the
                // paste/edit form is open (unlike the icons below) — nothing about being mid-edit
                // makes the current song's sync state stop mattering.
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
              if (!_showPasteForm)
                IconButton(
                  tooltip: '가사가 틀렸나요? 직접 입력',
                  icon: const Icon(Icons.edit_note, color: Colors.white70),
                  onPressed: () => setState(() => _showPasteForm = true),
                ),
              if (_isUserPasted)
                // Kept visible even while the paste form is open, same reasoning as the sync
                // icon above — it's the safety net for an accidental "전체 삭제", so hiding it
                // right when it's most likely to be needed would defeat the point.
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
                    // Pre-fills with what's already showing (pasted or fetched) so this is an
                    // edit of the existing lines rather than a blank retype from scratch — the
                    // auto-opened not-found case has nothing to pre-fill, so it starts with one
                    // empty line instead.
                    initialLines: _lines,
                    isSynced: _isSynced,
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
                      if (_isSynced)
                        _SyncOffsetBar(
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
                              // A synced song's per-line timestamps are worth protecting, so a
                              // long-press there corrects just that one line in place (see
                              // _editLine). An unsynced song has no timing to protect and no
                              // reliable "this exact line" concept to correct in isolation
                              // (nothing highlights a "current" line to begin with) — so editing
                              // there goes straight to the whole-song form instead.
                              onEdit: _isSynced
                                  ? () => _editLine(index)
                                  : () => setState(() => _showPasteForm = true),
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

// One lyric line's worth of editable text — original/phonetic/translation kept together as a
// unit (rather than three parallel lists matched by index) so adding, removing or reordering a
// line can never desync which phonetic/translation belongs to which original.
class _LineControllers {
  _LineControllers({
    String original = '',
    String phonetic = '',
    String translation = '',
    this.timestampMs,
  }) : original = TextEditingController(text: original),
       phonetic = TextEditingController(text: phonetic),
       translation = TextEditingController(text: translation);

  final TextEditingController original;
  final TextEditingController phonetic;
  final TextEditingController translation;
  // Carried through untouched from whatever this line already had (null for a brand new line,
  // or one that started out unsynced) — this is what lets correcting a synced song's text
  // through this same form keep its sync instead of losing it, see _save()'s _synced branch.
  final int? timestampMs;

  void dispose() {
    original.dispose();
    phonetic.dispose();
    translation.dispose();
  }
}

class _PasteLyricsForm extends StatefulWidget {
  const _PasteLyricsForm({
    required this.initialLines,
    required this.isSynced,
    required this.saving,
    required this.onSave,
    this.onCancel,
  });

  final List<LyricsLine> initialLines;
  // Picks which layout shows below — see _PasteLyricsFormState's class comment. A widget
  // property (not just read once in initState) because it needs to react live: the sync icon
  // stays reachable while this form is open specifically so toggling it here switches layouts
  // without closing and reopening the form.
  final bool isSynced;
  final bool saving;
  final void Function(List<LyricsLine> lines) onSave;
  // Present only when there's an existing (if wrong) result behind this form to go back to
  // without saving — null for the auto-opened not-found case, where there's nothing to cancel to.
  final VoidCallback? onCancel;

  @override
  State<_PasteLyricsForm> createState() => _PasteLyricsFormState();
}

// Two layouts, switched live off the sync toggle:
//  - Synced: one row per line (원문/독음/번역 kept together, stacked the same way the actual
//    reading view shows them) — a synced song's line-for-line structure is worth protecting, so
//    this corrects it in place rather than restructuring it.
//  - Unsynced: three separate plain-text fields (원문/독음/번역), each one song line per text
//    line, matched across the three by *position* (row 1 of 원문 pairs with row 1 of 독음 and
//    row 1 of 번역, and so on) rather than by interleaving all three tiers into a single field.
//    This used to be one field with every 3 lines read as 원문/독음/번역 back to back, which
//    silently scrambled an ordinary copy-paste (every 3rd real lyric line read as "원문", the
//    other two misread as that line's own 독음/번역). Three independent fields means a plain
//    paste into just the 원문 box (leaving 독음/번역 empty) still works exactly like a straight
//    copy-paste, while still letting all three tiers be filled in/corrected in bulk when wanted.
//    독음/번역 are allowed to have fewer lines than 원문 (또는 아예 비어 있음) — anything past
//    the end of a shorter field is just left null for that line.
// _lineGroups is the only place a real timestamp lives, and it's never rebuilt from the three
// fields' free-typed text — toggling to unsynced regenerates them fresh from _lineGroups every
// time (discarding whatever draft was in them before), and toggling back to synced just reveals
// _lineGroups again untouched. A draft typed into the three fields only actually takes effect if
// 저장 is pressed while still in the unsynced layout; switching back to synced first discards it.
// This is deliberately less "clever" than trying to re-split the free-typed text back into rows
// and re-match each one to its original timestamp by position — a single extra or missing line
// while typing would silently misalign everything after it and lose that line's (and every
// later line's) sync without any visible sign it had happened.
class _PasteLyricsFormState extends State<_PasteLyricsForm> {
  late List<_LineControllers> _lineGroups;
  late final TextEditingController _bulkOriginal;
  late final TextEditingController _bulkPhonetic;
  late final TextEditingController _bulkTranslation;
  late bool _synced;

  @override
  void initState() {
    super.initState();
    _synced = widget.isSynced;
    _lineGroups = widget.initialLines.isEmpty
        ? [_LineControllers()]
        : [
            for (final line in widget.initialLines)
              _LineControllers(
                original: line.original,
                phonetic: line.phonetic ?? '',
                translation: line.translation ?? '',
                timestampMs: line.timestampMs,
              ),
          ];
    _bulkOriginal = TextEditingController(
      text: _bulkTextFrom(_lineGroups, (g) => g.original.text),
    );
    _bulkPhonetic = TextEditingController(
      text: _bulkTextFrom(_lineGroups, (g) => g.phonetic.text),
    );
    _bulkTranslation = TextEditingController(
      text: _bulkTextFrom(_lineGroups, (g) => g.translation.text),
    );
  }

  String _bulkTextFrom(
    List<_LineControllers> groups,
    String Function(_LineControllers) pick,
  ) => [for (final group in groups) pick(group)].join('\n');

  @override
  void didUpdateWidget(covariant _PasteLyricsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSynced == _synced) return;
    // Synced -> unsynced: refresh the three fields from the current (untouched) rows, so they
    // start from what's actually showing rather than a stale draft from earlier.
    // Unsynced -> synced: nothing to do here — _lineGroups was never touched, so the rows
    // that reappear are already exactly what they were before the three fields ever showed.
    final wasSynced = _synced;
    setState(() {
      if (wasSynced) {
        _bulkOriginal.text = _bulkTextFrom(_lineGroups, (g) => g.original.text);
        _bulkPhonetic.text = _bulkTextFrom(_lineGroups, (g) => g.phonetic.text);
        _bulkTranslation.text = _bulkTextFrom(
          _lineGroups,
          (g) => g.translation.text,
        );
      }
      _synced = widget.isSynced;
    });
  }

  @override
  void dispose() {
    for (final group in _lineGroups) {
      group.dispose();
    }
    _bulkOriginal.dispose();
    _bulkPhonetic.dispose();
    _bulkTranslation.dispose();
    super.dispose();
  }

  void _clearAll() {
    setState(() {
      for (final group in _lineGroups) {
        group.dispose();
      }
      _lineGroups = [_LineControllers()];
      _bulkOriginal.clear();
      _bulkPhonetic.clear();
      _bulkTranslation.clear();
    });
  }

  void _save() {
    List<LyricsLine> lines;
    if (_synced) {
      lines = [
        for (final group in _lineGroups)
          LyricsLine(
            // Preserved from whatever this line already had — see _LineControllers'
            // timestampMs comment and savePastedLyrics()'s doc comment for why this is what
            // keeps correcting a synced song's text from also silently unsyncing it.
            timestampMs: group.timestampMs,
            original: group.original.text,
            phonetic: group.phonetic.text,
            translation: group.translation.text,
          ),
      ];
    } else {
      // A line's timestamp survives here if its 원문 text is still exactly what it was before
      // this song was ever toggled into this layout — matched by content, not position, so
      // reordering/inserting/deleting lines can't misalign anything the way position-based
      // matching did before. Only a line whose text was actually typed/changed (or one that's
      // brand new) loses its timing; every untouched line keeps auto-advancing normally.
      final originalTimestampByText = <String, int?>{};
      for (final group in _lineGroups) {
        originalTimestampByText.putIfAbsent(
          group.original.text,
          () => group.timestampMs,
        );
      }
      final originalLines = _bulkOriginal.text.split('\n');
      final phoneticLines = _bulkPhonetic.text.split('\n');
      final translationLines = _bulkTranslation.text.split('\n');
      lines = [
        for (var i = 0; i < originalLines.length; i++)
          LyricsLine(
            timestampMs: originalTimestampByText[originalLines[i]],
            original: originalLines[i],
            phonetic: i < phoneticLines.length ? phoneticLines[i] : null,
            translation: i < translationLines.length
                ? translationLines[i]
                : null,
          ),
      ];
    }
    widget.onSave(lines);
  }

  @override
  Widget build(BuildContext context) {
    final saving = widget.saving;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.onCancel != null ? '가사가 잘못됐나요?' : '가사를 찾을 수 없음',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  _synced
                      ? '한 줄씩 원문·독음·번역을 고치세요 — 독음/번역은 비워둬도 되고, 싱크 정보 없이 저장됩니다'
                      : '원문을 그대로 붙여넣으세요 (한 줄에 한 소절) — 독음·번역은 같은 줄 번호끼리 짝지어지며, 비워둬도 됩니다. 싱크 정보 없이 저장됩니다',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    // A pre-filled edit can be many lines long — a single tap to start over is
                    // faster than clearing every field by hand.
                    onPressed: saving ? null : _clearAll,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.white54,
                    ),
                    label: const Text(
                      '전체 삭제',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_synced)
                  for (var i = 0; i < _lineGroups.length; i++) _buildLineRow(i)
                else ...[
                  _buildField(
                    controller: _bulkOriginal,
                    hint: '원문을 여기에 붙여넣으세요 (필수)',
                    boxed: true,
                    minLines: 3,
                  ),
                  const SizedBox(height: 12),
                  _buildField(
                    controller: _bulkPhonetic,
                    hint: '독음 (선택, 원문과 같은 줄 순서로)',
                    boxed: true,
                    minLines: 3,
                  ),
                  const SizedBox(height: 12),
                  _buildField(
                    controller: _bulkTranslation,
                    hint: '번역 (선택, 원문과 같은 줄 순서로)',
                    boxed: true,
                    minLines: 3,
                  ),
                ],
              ],
            ),
          ),
        ),
        // Pinned below the scrolling content instead of as its last item — a long song's worth
        // of line groups pushed this well below the fold otherwise, making 저장 reachable only
        // after scrolling all the way down.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MetalButton(
                label: saving ? '저장 중...' : '저장',
                icon: Icons.save_outlined,
                onPressed: saving ? null : _save,
              ),
              if (widget.onCancel != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: saving ? null : widget.onCancel,
                  child: const Text(
                    '취소',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // No box, no border, no "N번 줄" label — three plain fields stacked directly on top of each
  // other, the same visual rhythm _LyricRow uses to actually display a line (원문 on top,
  // 독음 smaller/italic under it, 번역 under that), just editable instead of read-only. A
  // divider between rows is the only thing marking where one line ends and the next begins.
  Widget _buildLineRow(int index) {
    final group = _lineGroups[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildField(
            controller: group.original,
            hint: '원문 (필수)',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 4),
          _buildField(
            controller: group.phonetic,
            hint: '독음',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 4),
          _buildField(
            controller: group.translation,
            hint: '번역',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          if (index < _lineGroups.length - 1) ...[
            const SizedBox(height: 10),
            const Divider(color: MetalTheme.edgeHighlight, height: 1),
          ],
        ],
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    TextStyle? style,
    // True for the paste-in layout's big block (looks like a distinct text box to drop a
    // paste into), false for the correction layout's inline per-line fields (looks like plain
    // text, matching how the line already reads on the actual lyrics screen).
    bool boxed = false,
    int? minLines,
  }) {
    return TextField(
      controller: controller,
      maxLines: null,
      minLines: minLines,
      style: style ?? const TextStyle(color: Colors.white, fontSize: 14),
      decoration: boxed
          ? InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
              filled: true,
              fillColor: MetalTheme.surfaceDark,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(
                  color: MetalTheme.edgeHighlight,
                  width: 0.6,
                ),
              ),
            )
          : InputDecoration(
              isDense: true,
              isCollapsed: true,
              hintText: hint,
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
              border: InputBorder.none,
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
  const _LyricRow({
    required this.line,
    required this.isCurrent,
    required this.onEdit,
  });

  final LyricsLine line;
  final bool isCurrent;
  // Long-press to fix one line's 독음/번역 without discarding the whole song's sync — see
  // _FullScreenLyricsPageState._editLine. Long-press rather than a plain tap since a tap is
  // easy to trigger by accident while scrolling through the list.
  final VoidCallback onEdit;

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
    return InkWell(
      onLongPress: onEdit,
      child: Padding(
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
                    (isCurrent
                        ? _originalFontRatioCurrent
                        : _originalFontRatio),
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
