import 'package:flutter/material.dart';

import '../../data/hive/models/recent_song_entry.dart';
import '../theme/metal_theme.dart';

/// Every song this device has ever fetched lyrics for, newest-played first — the home
/// screen's "최근 들은 곡" only shows a short capped list (see HomePage._recentSongsDisplayCount),
/// so this is where the rest of that same index is actually browsable, with its own search
/// field to narrow it down (the home screen's search field only ever shows the top matches,
/// not the full list this page has).
class SavedSongsListPage extends StatefulWidget {
  const SavedSongsListPage({
    super.key,
    required this.songs,
    required this.onOpen,
    required this.onDelete,
  });

  final List<RecentSongEntry> songs;
  final void Function(RecentSongEntry entry) onOpen;
  // Removes the entry from both the recent-songs index and the lyrics cache it points at
  // (see HomePage._deleteSavedSong) — awaited before this page drops it from its own local
  // list, so a failed delete doesn't leave the row missing from the UI while still on disk.
  final Future<void> Function(RecentSongEntry entry) onDelete;

  @override
  State<SavedSongsListPage> createState() => _SavedSongsListPageState();
}

class _SavedSongsListPageState extends State<SavedSongsListPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  // A local copy so a delete can remove the row immediately without waiting on the parent
  // route to rebuild this page with a fresh `widget.songs` list.
  late List<RecentSongEntry> _songs;

  @override
  void initState() {
    super.initState();
    _songs = List.of(widget.songs);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<RecentSongEntry> get _filteredSongs {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return _songs;
    return _songs
        .where(
          (entry) =>
              entry.title.toLowerCase().contains(needle) ||
              entry.artist.toLowerCase().contains(needle),
        )
        .toList();
  }

  Future<bool> _confirmDelete(RecentSongEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: MetalTheme.surfaceDark,
        title: const Text('저장된 곡 삭제', style: TextStyle(color: Colors.white)),
        content: Text(
          '"${entry.title}"${entry.artist.isEmpty ? '' : ' - ${entry.artist}'}을(를) 삭제할까요?\n저장된 가사도 함께 삭제되며 되돌릴 수 없어요.',
          style: const TextStyle(color: MetalTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final filtered = _filteredSongs;
    return Scaffold(
      backgroundColor: MetalTheme.base,
      appBar: AppBar(
        backgroundColor: MetalTheme.base,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '저장된 곡 (${_songs.length})',
          style: TextStyle(
            color: Colors.white,
            fontSize: screenWidth * 0.05,
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: MetalTheme.backgroundGradient),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  MediaQuery.of(context).size.width * 0.0444,
                  16,
                  MediaQuery.of(context).size.width * 0.0444,
                  8,
                ),
                child: _buildSearchField(context),
              ),
              Expanded(
                child: _songs.isEmpty
                    ? const Center(
                        child: Text(
                          '저장된 곡이 없습니다',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : filtered.isEmpty
                    ? const Center(
                        child: Text(
                          '일치하는 곡이 없습니다',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.fromLTRB(
                          MediaQuery.of(context).size.width * 0.0444,
                          0,
                          MediaQuery.of(context).size.width * 0.0444,
                          MediaQuery.of(context).size.height * 0.02,
                        ),
                        itemCount: filtered.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          return Dismissible(
                            key: ValueKey(entry.cacheKey),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.delete_outline, color: Colors.white),
                            ),
                            confirmDismiss: (_) => _confirmDelete(entry),
                            onDismissed: (_) {
                              setState(() => _songs.remove(entry));
                              widget.onDelete(entry);
                            },
                            child: MetalCard(
                              padding: EdgeInsets.zero,
                              child: ListTile(
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
                                onTap: () => widget.onOpen(entry),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Same 360dp-reference ratio pattern the home screen's own search field uses.
  Widget _buildSearchField(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    const textRatio = 0.0444; // 16/360
    const iconRatio = 0.05; // 18/360
    return TextField(
      controller: _searchController,
      onChanged: (value) => setState(() => _query = value),
      style: TextStyle(color: Colors.white, fontSize: screenWidth * textRatio),
      decoration: InputDecoration(
        hintText: '곡 제목이나 가수로 검색',
        hintStyle: TextStyle(
          color: MetalTheme.textMuted,
          fontSize: screenWidth * textRatio,
        ),
        prefixIcon: Icon(
          Icons.search,
          color: MetalTheme.steel,
          size: screenWidth * iconRatio,
        ),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: Icon(
                  Icons.clear,
                  color: MetalTheme.textMuted,
                  size: screenWidth * iconRatio,
                ),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = '');
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
}
