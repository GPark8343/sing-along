import 'package:flutter/material.dart';

import '../../data/repositories/lyrics_repository.dart';

/// A plain, static read-out of a previously-cached song's lyrics — opened from the home
/// screen's "최근 들은 곡" list, for a song that isn't necessarily playing right now. Unlike
/// [FullScreenLyricsPage] this has no live position/track-change stream to follow (there may
/// be nothing playing at all), no paste-in/refetch editing, and no sync toggle — just the
/// original/phonetic/translation lines, scrollable, for reading on their own.
class SavedLyricsViewPage extends StatelessWidget {
  const SavedLyricsViewPage({
    super.key,
    required this.title,
    required this.artist,
    required this.lines,
  });

  final String title;
  final String artist;
  final List<LyricsLine> lines;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          artist.isEmpty ? title : '$title - $artist',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
      body: lines.isEmpty
          ? const Center(
              child: Text(
                '저장된 가사가 없습니다',
                style: TextStyle(color: Colors.white54),
              ),
            )
          // The AppBar already accounts for the top inset, so only the bottom (system
          // navigation bar — gesture pill or 3-button bar, whichever the device uses) needs
          // guarding here; without it the last line or two renders right under/behind that bar.
          : SafeArea(
              top: false,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(
                  vertical: 24,
                  horizontal: 24,
                ),
                itemCount: lines.length,
                itemBuilder: (context, index) =>
                    _StaticLyricRow(line: lines[index]),
              ),
            ),
    );
  }
}

class _StaticLyricRow extends StatelessWidget {
  const _StaticLyricRow({required this.line});

  final LyricsLine line;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.original,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (line.phonetic != null) ...[
            const SizedBox(height: 2),
            Text(
              line.phonetic!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (line.translation != null) ...[
            const SizedBox(height: 2),
            Text(
              line.translation!,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }
}
