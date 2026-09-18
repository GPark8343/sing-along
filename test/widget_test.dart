import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'package:sing_along/data/hive/hive_bootstrap.dart';
import 'package:sing_along/data/hive/models/cached_lyric_line.dart';
import 'package:sing_along/data/hive/models/cached_lyrics_entry.dart';
import 'package:sing_along/data/hive/models/recent_song_entry.dart';
import 'package:sing_along/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const notificationChannel = MethodChannel('sing_along/notification');
  const overlayChannel = MethodChannel('x-slayer/overlay_channel');
  const positionChannel = EventChannel('sing_along/playback_position');

  setUpAll(() async {
    final tempDir = await Directory.systemTemp.createTemp('sing_along_test');
    Hive.init(tempDir.path);
    Hive.registerAdapter(CachedLyricsEntryAdapter());
    Hive.registerAdapter(CachedLyricLineAdapter());
    Hive.registerAdapter(RecentSongEntryAdapter());
  });

  setUp(() {
    messenger.setMockMethodCallHandler(notificationChannel, (call) async {
      switch (call.method) {
        case 'isNotificationAccessGranted':
          return false;
        case 'getCurrentMedia':
          return null;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(overlayChannel, (call) async {
      switch (call.method) {
        case 'checkPermission':
          return false;
        case 'isOverlayActive':
          return false;
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      positionChannel,
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(notificationChannel, null);
    messenger.setMockMethodCallHandler(overlayChannel, null);
    messenger.setMockStreamHandler(positionChannel, null);
  });

  testWidgets('Home page renders permission onboarding', (WidgetTester tester) async {
    final lyricsBox = await Hive.openBox<CachedLyricsEntry>('widget_test_lyrics_cache');
    final recentSongsBox = await Hive.openBox<RecentSongEntry>('widget_test_recent_songs');
    await tester.pumpWidget(SingAlongApp(boxes: HiveBoxes(lyrics: lyricsBox, recentSongs: recentSongsBox)));
    await tester.pump();

    expect(find.text('sing-along'), findsOneWidget);
    expect(find.text('알림 접근 권한'), findsOneWidget);
    expect(find.text('다른 앱 위에 표시'), findsOneWidget);
  });
}
