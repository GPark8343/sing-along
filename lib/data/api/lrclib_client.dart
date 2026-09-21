import 'package:dio/dio.dart';

import '../../core/text/hangul_romanizer.dart';
import '../../core/text/japanese_detector.dart';

/// Raw lyrics as returned by LRCLIB — no auth/rate limit, so no key handling
/// needed for this leg of the pipeline (unlike Goo Lab/DeepL later).
class LrclibLyrics {
  final String? plainLyrics;
  final String? syncedLyrics; // LRC text: "[mm:ss.xx] line" per line, when available
  final bool instrumental;

  const LrclibLyrics({
    required this.plainLyrics,
    required this.syncedLyrics,
    required this.instrumental,
  });

  bool get hasSyncedLyrics => syncedLyrics?.trim().isNotEmpty ?? false;

  bool get hasLyrics => !instrumental && (hasSyncedLyrics || (plainLyrics?.trim().isNotEmpty ?? false));
}

class LrclibClient {
  LrclibClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://lrclib.net/api',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ));

  final Dio _dio;

  static final RegExp _titleSplitPattern = RegExp(r'\s*[-–/／]\s*');

  /// Looks up a song by exact `/get` and title-candidate `/search`, fired in parallel. A
  /// `/search` result is only ever accepted when its title and artist match the query exactly
  /// (case/whitespace-insensitive, see `_searchExact`) — no fuzzy scoring, no partial credit.
  /// Showing a confidently wrong song's lyrics is worse than honestly saying "not found".
  Future<LrclibLyrics?> fetchLyrics({
    required String trackName,
    required String artistName,
    int? durationSeconds,
  }) async {
    final result = await _fetchLyricsOnce(trackName, artistName, durationSeconds);
    if (result != null) return result;
    // Some Korean media apps substitute the title and/or artist with its Hangul *phonetic
    // reading* for a Korean audience instead of the original spelling — "아도" for "Ado",
    // "레이도메이도" for some Japanese/English title — which shares no characters at all with
    // LRCLIB's own Latin/Japanese-script fields no matter how correct the match is. A plain
    // query against that Hangul text was never going to find anything, so this doesn't run
    // unless it already didn't: reverse any Hangul in either field back to its approximate
    // Latin spelling (a real transliteration, not a lookup table — see HangulRomanizer) and
    // retry the exact same lookup once with that instead. Kept sequential, not raced against
    // the original attempt — each attempt already fires several requests of its own, and
    // running two full copies at once was found to overwhelm a real mobile connection
    // (everything started timing out) rather than actually finishing faster.
    final hasHangul = HangulRomanizer.containsHangul(trackName) ||
        HangulRomanizer.containsHangul(artistName);
    if (!hasHangul) return null;
    return _fetchLyricsOnce(
      HangulRomanizer.romanize(trackName),
      HangulRomanizer.romanize(artistName),
      durationSeconds,
    );
  }

  Future<LrclibLyrics?> _fetchLyricsOnce(
    String trackName,
    String artistName,
    int? durationSeconds,
  ) async {
    // /get and /search don't depend on each other at all, so both fire up front instead of
    // waiting for /get to miss first — LRCLIB's own response time (several seconds per
    // request on a real mobile connection, not milliseconds) makes serializing them a bad
    // trade on every miss, which is the common case (a notification's title/artist rarely
    // matches LRCLIB's own fields closely enough for /get to hit at all).
    final exactFuture = _getExactWithAlias(trackName, artistName, durationSeconds);

    final candidates = _titleCandidates(trackName, artistName);
    final searchFuture = _searchExact(candidates, trackName, artistName, durationSeconds);

    // Both requests started above and are already in flight — but only /get is *awaited*
    // here. When it comes back with a synced hit, that's the best possible answer and there's
    // no reason to sit around for /search too just because it happened to be fired at the same
    // time (it commonly takes noticeably longer, being several requests in its own right).
    // /search keeps running in the background regardless; this only decides whether its result
    // is ever looked at.
    final exact = await exactFuture;
    if (exact != null && exact.hasSyncedLyrics) return exact;

    final searched = await searchFuture;
    if (searched != null && searched.hasSyncedLyrics) return searched;
    // Neither source had a synced version — fall back to whichever had lyrics at all,
    // preferring the exact match since it's the more precisely-identified record.
    return exact ?? searched;
  }

  // A last-resort fallback for when the exact recording has no LRCLIB entry of its own at
  // all — only a differently-arranged version does (e.g. the studio single "Leo" has nothing,
  // but "Leo -Orchestral Arrangement Version-" does). fetchLyrics() already tried and failed
  // to find a confident match by this point; this is deliberately much looser — it only
  // requires the candidate's title to literally start with the query title (so it can't drift
  // onto a wholly unrelated song sharing a few letters) plus a confident artist match — since
  // the caller always discards whatever timing comes back and shows the text unsynced. A
  // different arrangement's line-by-line wording can also differ (an extended intro, a spoken
  // interlude), but that's still a far more useful starting point than nothing at all.
  Future<LrclibLyrics?> fetchLooseLyrics({
    required String trackName,
    required String artistName,
  }) async {
    if (artistName.isEmpty) return null;
    final candidates = _titleCandidates(trackName, artistName);
    final aliases = _artistAliasesFor(artistName);
    Map<String, dynamic>? best;
    // Each candidate's /search is independent, so they run concurrently instead of one after
    // another — including once per alias, for the same reason _searchExact() queries them too
    // (LRCLIB's /search never surfaces a kanji-credited submission for a romaji artist query).
    final searchResults = await Future.wait([
      for (final candidate in candidates) _search(candidate, artistName),
      for (final alias in aliases) for (final candidate in candidates) _search(candidate, alias),
    ]);
    for (var i = 0; i < searchResults.length; i++) {
      final candidate = candidates[i % candidates.length];
      // Checked against *this* candidate specifically, not the original combined trackName —
      // a bilingual title like "レオ - Leo" needs to compare against its own "Leo" half, since
      // no LRCLIB entry's title will ever start with the whole untouched original string.
      final normalizedCandidate = candidate.trim().toLowerCase();
      if (normalizedCandidate.isEmpty) continue;
      final results = searchResults[i];
      for (final entry in results) {
        final entryTitle = ((entry['trackName'] as String?) ?? '').trim().toLowerCase();
        if (!_isTitleVariantOf(normalizedCandidate, entryTitle)) continue;
        final entryArtist = (entry['artistName'] as String?) ?? '';
        // A known alias counts as a match outright — comparing "米津玄師" against a query of
        // "Kenshi Yonezu" via plain string/token similarity scores close to zero despite being
        // the same artist, so _artistSimilarity alone would reject every one of these.
        final artistOk = _artistMatches(artistName.trim().toLowerCase(), entryArtist.trim().toLowerCase()) ||
            _artistSimilarity(artistName, entryArtist) >= 0.7;
        if (!artistOk) continue;
        if (_isRomanizedMismatch(entry, trackName, artistName)) continue;
        if (_isContaminatedSubmission(entry)) continue;
        // Among ties, prefer whichever title is closest to the query (shortest match) —
        // e.g. an "-Acoustic Version-" over an "-Orchestral Arrangement, Live at Budokan-".
        final bestTitle = best == null ? null : ((best['trackName'] as String?) ?? '').trim().toLowerCase();
        if (best == null || entryTitle.length < (bestTitle?.length ?? 0)) {
          best = entry;
        }
      }
    }
    return best == null ? null : _parse(best);
  }

  // True when `candidateTitle` is the query title with something appended after a word
  // boundary (a space, hyphen, bracket, ...) — "leo -orchestral arrangement version-" counts
  // for query "leo", but "leon" doesn't, and neither does an unrelated title that merely
  // contains the query as a substring in the middle.
  bool _isTitleVariantOf(String queryTitle, String candidateTitle) {
    if (candidateTitle.isEmpty || !candidateTitle.startsWith(queryTitle)) return false;
    if (candidateTitle.length == queryTitle.length) return false; // identical — not a "variant"
    final nextChar = candidateTitle[queryTitle.length];
    return !RegExp(r'[a-z0-9]').hasMatch(nextChar);
  }

  // A YouTube-style "Artist - Title" notification title, once normalized, still splits into
  // ["Artist", "Title"] here — searching LRCLIB with the artist fragment AS a title candidate
  // is worse than just skipping it: LRCLIB submissions often carry that same "Artist - Title"
  // convention in their own trackName field, so an "artist name" candidate can wrongly exact-
  // match a *completely different song* by that artist that just happens to be formatted the
  // same way — exactly the "matched the wrong song" failure mode this is guarding against, not
  // a genuine alternate phrasing of the real title.
  List<String> _titleCandidates(String trackName, String artistName) {
    final candidates = <String>[trackName];
    for (final part in trackName.split(_titleSplitPattern)) {
      final trimmed = part.trim();
      if (trimmed.isEmpty || candidates.contains(trimmed)) continue;
      if (artistName.isNotEmpty && _similarity(trimmed, artistName) > 0.8) continue;
      candidates.add(trimmed);
    }
    return candidates;
  }

  // Some artists' LRCLIB submissions are filed under a completely different script than what a
  // streaming app displays — e.g. YouTube Music shows "Kenshi Yonezu" but the submission's own
  // artistName is "米津玄師" — sharing not one character with the query, so no exact-match rule
  // over the strings themselves can ever bridge it. Unlike a kanji *title*, there's no reliable
  // algorithm for this either: the reading of a Japanese name isn't recoverable from the kanji
  // alone (the same characters can be read several different ways depending on the person), so
  // this is a plain lookup table instead of an attempt at general kanji-to-romaji machinery.
  //
  // Each inner list is one artist's known spellings — Korean phonetic transliteration (how
  // Korean fan communities/media commonly write the name), English/romaji, and Japanese
  // script(s) — checked against real LRCLIB submissions rather than assumed: some artists turn
  // out to be filed under romaji already (Fujii Kaze), some under kanji with several
  // inconsistent variants across different contributors' submissions (Hoshino Gen), and some
  // under a kanji/hiragana mix (Hoshimachi Suisei). Extend this as new mismatches turn up
  // rather than trying to cover every artist in advance.
  static const List<List<String>> _artistAliasGroups = [
    ['요네즈 켄시', 'Kenshi Yonezu', '米津玄師'],
    // Kept separate from the group above rather than merged in — same real person (his early
    // Vocaloid-producer name before going by his own name), but LRCLIB credits songs from that
    // era to "ハチ"/"Hachi" specifically, not 米津玄師, so treating them as one alias group
    // would risk pulling in a Hachi-era submission for a query that's actually about his later
    // work under his own name, or the reverse.
    ['하치', 'Hachi', 'ハチ'],
    ['우타다 히카루', 'Utada Hikaru', '宇多田ヒカル', '宇多田 ヒカル'],
    ['호시노 겐', 'Hoshino Gen', 'Gen Hoshino', '星野源', '星野 源'],
    ['후지이 카제', 'Fujii Kaze', '藤井風', '藤井 風'],
    ['유리', '유우리', 'Yuuri', 'Yuri', '優里', 'ゆうり'],
    ['아키야마 키이로', 'Akiyama Kiiro', '秋山黄色'],
    ['스다 마사키', 'Suda Masaki', 'Masaki Suda', '菅田将暉', 'すだまさき'],
    ['오카자키 타이이쿠', 'Okazaki Taiiku', '岡崎体育'],
    ['사키야마 소시', 'Sakiyama Soshi', '崎山蒼志'],
    ['카미야마 요', 'Kamiyama Yo', '神山羊'],
    ['카프', 'Kaf', '花譜'], // VTuber (KAMITSUBAKI STUDIO)

    // 유명 가수 및 밴드 (singers & bands)
    ['아이묭', 'Aimyon', 'あいみょん'],
    ['아도', 'Ado', 'アド'],
    ['요아소비', 'YOASOBI', 'ヨアソビ'],
    ['요루시카', 'Yorushika', 'ヨルシカ'],
    ['즛토마요', 'ZUTOMAYO', 'Zutomayo', 'ずっと真夜中でいいのに。', 'ずっとまよなかでいいのに。'],
    ['오피셜 히게 단디즘', 'Official Hige Dandism', 'Official髭男dism', 'オフィシャルヒゲダンディズム'],
    ['킹 누', 'King Gnu', 'キングヌー'],
    ['에메', 'Aimer', 'エメ'],
    ['리사', 'LiSA', 'リサ'],
    ['바운디', 'Vaundy', 'バウンディ'],
    ['이브', 'Eve', 'イブ'],
    ['이마세', 'imase', 'イマセ'],
    ['나토리', 'natori', 'なとり'],
    ['키타니 타츠야', 'Tatsuya Kitani', 'キタニタツヤ'],
    ['수요일의 캄파넬라', 'Wednesday Campanella', '水曜日のカンパネラ', 'すいようびのカンパネラ'],
    ['험프 백', 'Hump Back', 'ハンプバック'],
    ['범프 오브 치킨', 'BUMP OF CHICKEN', 'バンプ・オブ・チキン'],
    ['래드윔프스', 'RADWIMPS', 'ラッドウィンプス'],
    ['원 오크 록', 'ONE OK ROCK', 'ワンオクロック'],

    // 버튜버 (VTubers)
    ['호시마치 스이세이', 'Hoshimachi Suisei', '星街すいせい', 'ほしまちすいせい'],
    ['호쇼 마린', 'Houshou Marine', '宝鐘マリン', 'ほうしょうマリン'],
    ['우사다 페코라', 'Usada Pekora', '兎田ぺこら', 'うさだぺこら'],
    ['시라카미 후부키', 'Shirakami Fubuki', '白上フブキ', 'しらかみフブキ'],
    ['미나토 아쿠아', 'Minato Aqua', '湊あくあ', 'みなとあくあ'],
    ['토코야미 토와', 'Tokoyami Towa', '常闇トワ', 'とこやみトワ'],
    ['쿠즈하', 'Kuzuha', '葛葉', 'くずは'],
    ['카나에', 'Kanae', '叶', 'かなえ'],
    ['햐쿠만텐바라 살로메', 'Hyakumantenbara Salome', '壱百満天原サロメ', 'ひゃくまんてんばらサロメ'],

    // 보컬로이드 및 음성 합성 소프트웨어 캐릭터 (Vocaloids & SynthV)
    ['하츠네 미쿠', 'Hatsune Miku', '初音ミク', 'はつねミク'],
    ['카가미네 린', 'Kagamine Rin', '鏡音リン', 'かがみねリン'],
    ['카가미네 렌', 'Kagamine Len', '鏡音レン', 'かがみねレン'],
    ['메구리네 루카', 'Megurine Luka', '巡音ルカ', 'めぐりねルカ'],
    ['카이토', 'KAITO', 'カイト'],
    ['메이코', 'MEIKO', 'メイコ'],
    ['구미', 'GUMI', 'Megpoid', 'メグッポイド', 'グミ'],
    ['카후', 'KAFU', '可不', 'かふ'],
    ['카사네 테토', 'Kasane Teto', '重音テト', 'かさねテト'],

    // 유명 가수 및 밴드 (singers & bands) - 추가
    ['미세스 그린 애플', 'Mrs. GREEN APPLE', 'ミセスグリーンアップル'],
    ['세카이노 오와리', 'SEKAI NO OWARI', '世界の終わり', 'セカイノオワリ'],
    ['백 넘버', 'back number', 'バックナンバー'],
    ['스피츠', 'Spitz', 'スピッツ'],
    ['미레이', 'milet', 'ミレイ'],
    ['야마', 'yama', 'ヤマ'],
    ['사유리', 'Sayuri', 'さユり'],
    ['미나미', 'Minami', '美波', 'みなみ'],
    ['마카로니 엔피츠', 'Macaroni Empitsu', 'マカロニえんぴつ'],
    ['사우시 독', 'Saucy Dog', 'サウシードッグ'],
    ['우버월드', 'UVERworld', 'ウーバーワールド'],
    ["라르크 앙 시엘", "L'Arc~en~Ciel", 'ラルク アン シエル'],
    ['포르노 그라피티', 'Porno Graffitti', 'ポルノグラフィティ'],
    ['녹황색사회', 'Ryokuoushoku Shakai', '緑黄色社会', 'りょくおうしょくしゃかい'],

    // 우타이테 및 유명 보컬로이드 프로듀서 (utaite & Vocaloid producers)
    ['마후마후', 'Mafumafu', 'まふまふ'],
    ['소라루', 'Soraru', 'そらる'],
    ['데코니나', 'DECO*27', 'デコニーナ'],
    ['피노키오피', 'PinocchioP', 'ピノキオピー'],
    ['슈도', 'syudou', 'しゅどう'],
    ['나유탄 성인', 'Nayutalien', 'ナユタン星人', 'ナユタンせいじん'],
    ['오렌지스타', 'Orangestar', 'オレンジスター'],
    ['키쿠오', 'Kikuo', 'きくお'],
    ['나부나', 'n-buna', 'ナブナ'],

    // 버튜버 (VTubers) - 추가
    ['사쿠라 미코', 'Sakura Miko', 'さくらみこ'],
    ['이누가미 코로네', 'Inugami Korone', '戌神ころね', 'いぬがみころね'],
    ['오오조라 스바루', 'Oozora Subaru', '大空スバル', 'おおぞらスバル'],
    ['모리 칼리오페', 'Mori Calliope', '森カリオペ', 'もりカリオペ'],
    ['가우르 구라', 'Gawr Gura', 'がうる・ぐら'],
    ['츠키노 미토', 'Tsukino Mito', '月ノ美兎', 'つきのみと'],
    ['켄모치 토우야', 'Kenmochi Toya', '剣持刀也', 'けんもちとうや'],
    ['호시카와 사라', 'Hoshikawa Sara', '星川サラ', 'ほしかわサラ'],
    ['로렌 이로아스', 'Lauren Iroas', 'ローレン・イロアス'],

    // 보컬로이드 및 음성 합성 소프트웨어 캐릭터 (Vocaloids & SynthV) - 추가
    ['이아', 'IA', 'イア'],
    ['브이 플라워', 'v flower', 'ブイフラワ', 'フラワ'],
    ['유즈키 유카리', 'Yuzuki Yukari', '結月ゆかり', 'ゆづきゆかり'],
    ['오토마치 우나', 'Otomachi Una', '音街ウナ', 'おとまちウナ'],
    ['카무이 가쿠포', 'Gackpoid (Kamui Gakupo)', '神威がくぽ', 'かむいがくぽ'],
    ['카아이 유키', 'Kaai Yuki', '歌愛ユキ', 'かあいユキ'],

    // 유명 가수 및 밴드 (singers & bands) - 추가 2
    ['아라시', 'ARASHI', '嵐', 'あらし'],
    ['엑스 재팬', 'X JAPAN', 'エックスジャパン'],
    ['자드', 'ZARD', 'ザード'],
    ['아무로 나미에', 'Namie Amuro', '安室奈美恵', 'あむろなみえ'],
    ['미스터 칠드런', 'Mr.Children', 'ミスターチルドレン'],
    ["비즈", "B'z", 'ビーズ'],
    ['디시', 'DISH//', 'ディッシュ'],
    ['퍼퓸', 'Perfume', 'パフューム'],
    ['사잔 올 스타즈', 'Southern All Stars', 'サザンオールスターズ'],
    ['나카시마 미카', 'Mika Nakashima', '中島美嘉', 'なかしまみか'],
    ['아야카', 'ayaka', '絢香', 'あやか'],
    ['노벨브라이트', 'Novelbright', 'ノーベルブライト'],
    ['그린', 'GReeeeN', 'グリーン'],

    // 우타이테 및 유명 보컬로이드 프로듀서 (utaite & Vocaloid producers) - 추가 2
    ['레올', 'Reol', 'レヲル'],
    ['아마츠키', 'Amatsuki', '天月', 'あまつき'],
    ['쿠로네코', '96neko', '96猫', 'くろねこ'],
    ['카나리아', 'Kanaria', 'カナリア'],
    ['기가', 'Giga', 'ギガ'],
    ['네루', 'Neru', 'ネル'],
    ['미치 엠', 'Mitchie M', 'ミッチーエム'],
    ['케무', 'kemu', 'ケム'],
    ['토아', 'Toa', 'とあ'],
    ['벌룬', 'Balloon', 'バルーン'],

    // 버튜버 (VTubers) - 추가 2
    ['나키리 아야메', 'Nakiri Ayame', '百鬼あやめ', 'なきりあやめ'],
    ['네코마타 오카유', 'Nekomata Okayu', '猫又おかゆ', 'ねこまたおかゆ'],
    ['츠노마키 와타메', 'Tsunomaki Watame', '角巻わため', 'つのまきわため'],
    ['시시로 보탄', 'Shishiro Botan', '獅白ぼたん', 'ししろぼたん'],
    ['유키하나 라미', 'Yukihana Lamy', '雪花ラミィ', 'ゆきはなラミィ'],
    ['라플라스 다크니스', 'La+ Darknesss', 'ラプラス・ダークネス'],
    ['카가미 하야토', 'Kagami Hayato', '加賀美ハヤト', 'かがみハヤト'],
    ['후와 미나토', 'Fuwa Minato', '不破湊', 'ふわみなと'],
    ['시키나기 아키라', 'Shikinagi Akira', '四季凪アキラ', 'しきなぎアキラ'],
    ['우루하 루시아', 'Uruha Rushia', '潤羽るしあ', 'うるはるしあ'],

    // 보컬로이드 및 음성 합성 소프트웨어 캐릭터 (Vocaloids & SynthV) - 추가 2
    ['토호쿠 즌코', 'Tohoku Zunko', '東北ずん子', 'とうほくずんこ'],
    ['토호쿠 키리탄', 'Tohoku Kiritan', '東北きりたん', 'とうほくきりたん'],
    ['코토노하 아카네', 'Kotonoha Akane', '琴葉茜', 'ことのはあかね'],
    ['코토노하 아오이', 'Kotonoha Aoi', '琴葉葵', 'ことのはあおい'],
    ['츠루마키 마키', 'Tsurumaki Maki', '弦巻マキ', 'つるまきマキ'],
    ['요와네 하쿠', 'Yowane Haku', '弱音ハク', 'よわねハク'],
    ['아키타 네루', 'Akita Neru', '亞北ネル', 'あきたネル'],
    ['마쿠네 나나', 'Macne Nana', 'Mac音ナナ', 'マクねナナ'],

    // 스텔라이브 (StelLive) — 한국에서 활동하는 대표적인 일본식 이름 버튜버
    ['아이리 칸나', 'Airi Kanna', '藍璃かんな', 'あいりかんな'],
    ['아야츠노 유니', 'Ayatsuno Yuni', '純角ユニ', 'あやつのユニ'],
    ['시라유키 히나', 'Shirayuki Hina', '白雪ひな', 'しらゆきひな'],
    ['네네코 마시로', 'Neneko Mashiro', 'ねねこましろ'], // 공식 한자 표기 없음
    ['아카네 리제', 'Akane Lize', '朱音リゼ', 'あかねリゼ'],
    ['아라하시 타비', 'Arahashi Tabi', '荒波子タビ', 'あらはしタビ'],
    ['아오쿠모 린', 'Aokumo Rin', '青雲凛', 'あおくもりん'],
    ['텐코 시부키', 'Tenko Shibuki', '天狐紫吹', 'てんこしぶき'],
    ['하나코 나나', 'Hanako Nana', '花子ナナ', 'はなこナナ'],
    ['유즈하 리코', 'Yuzuha Riko', '柚葉莉子', 'ゆずはりこ'],

    // 기타 한국 활동 이력이 있는 일본식 이름 버튜버
    ['아키라 레이', 'Akira Ray', '明楽レイ', 'あきらレイ'],
    ['아리스 마나', 'Alice Mana', 'アリス・マナ'],
  ];

  // True when `queryArtist` and `entryArtist` (both already lowercased/trimmed) are the same
  // string, or both appear in the same alias group above — either side could be the one
  // LRCLIB happens to have on file, so this doesn't assume a fixed direction.
  bool _artistMatches(String queryArtist, String entryArtist) {
    if (queryArtist == entryArtist) return true;
    for (final group in _artistAliasGroups) {
      final lowered = group.map((s) => s.toLowerCase());
      if (lowered.contains(queryArtist) && lowered.contains(entryArtist)) return true;
    }
    return false;
  }

  // Every other spelling in `artistName`'s alias group, if it's in one at all — empty when
  // the artist isn't a known alias case (the overwhelmingly common case), so callers can skip
  // the extra requests entirely rather than firing them just to come back empty.
  List<String> _artistAliasesFor(String artistName) {
    final normalized = artistName.trim().toLowerCase();
    for (final group in _artistAliasGroups) {
      if (group.any((s) => s.toLowerCase() == normalized)) {
        return [for (final s in group) if (s.toLowerCase() != normalized) s];
      }
    }
    return const [];
  }

  // Every candidate's /search is an independent request, so all fire together instead of one
  // at a time. Only a result whose title and artist match the query *exactly*
  // (case/whitespace-insensitive) is accepted — no fuzzy scoring, no partial credit, no
  // fallback to a looser query when nothing matches. LRCLIB's own /search already does the
  // fuzzy ranking; this only has to recognize when one of its results is actually the right
  // song rather than guessing how close is close enough.
  Future<LrclibLyrics?> _searchExact(
    List<String> titleCandidates,
    String trackName,
    String artistName,
    int? durationSeconds,
  ) async {
    final normalizedCandidates = titleCandidates.map((c) => c.trim().toLowerCase()).toSet();
    final normalizedArtist = artistName.trim().toLowerCase();
    // LRCLIB's /search only returns results that already resemble the *query* artist string —
    // querying "Kenshi Yonezu" never surfaces 米津玄師's own (correctly-scripted) submissions
    // at all, only whatever stray romanized-lyrics ones happen to share that spelling. Post-
    // filtering with _artistMatches below can't fix that: it only accepts or rejects results
    // LRCLIB actually sent back, and the right ones were never in the response to begin with.
    // So known aliases get queried too, not just checked for afterward.
    final aliases = _artistAliasesFor(artistName);

    final searchResults = await Future.wait([
      for (final candidate in titleCandidates) _search(candidate, artistName),
      for (final alias in aliases)
        for (final candidate in titleCandidates) _search(candidate, alias),
    ]);

    Map<String, dynamic>? best;
    for (final results in searchResults) {
      for (final entry in results) {
        final entryTitle = ((entry['trackName'] as String?) ?? '').trim().toLowerCase();
        final entryArtist = ((entry['artistName'] as String?) ?? '').trim().toLowerCase();
        if (!normalizedCandidates.contains(entryTitle)) continue;
        if (normalizedArtist.isNotEmpty && !_artistMatches(normalizedArtist, entryArtist)) continue;
        if (_isRomanizedMismatch(entry, trackName, artistName)) continue;
        if (_isContaminatedSubmission(entry)) continue;
        best = _preferred(best, entry, durationSeconds);
      }
    }
    return best == null ? null : _parse(best);
  }

  // Among multiple exact title/artist matches (different contributors' submissions of the
  // same recording), prefers a synced one over a plain one, and — between two that are both
  // synced or both plain — whichever duration is closer to the one actually playing, so a
  // studio cut doesn't get mixed up with a live/extended version sharing the same title and
  // artist.
  Map<String, dynamic> _preferred(
    Map<String, dynamic>? current,
    Map<String, dynamic> candidate,
    int? durationSeconds,
  ) {
    if (current == null) return candidate;
    final currentSynced = (current['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false;
    final candidateSynced = (candidate['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false;
    if (candidateSynced != currentSynced) return candidateSynced ? candidate : current;
    if (durationSeconds == null) return current;
    return _durationDiff(candidate, durationSeconds) < _durationDiff(current, durationSeconds)
        ? candidate
        : current;
  }

  int _durationDiff(Map<String, dynamic> entry, int durationSeconds) {
    final entryDuration = (entry['duration'] as num?)?.toInt();
    if (entryDuration == null) return 1 << 30; // unknown — sorts last
    return (entryDuration - durationSeconds).abs();
  }

  // LRCLIB occasionally has a submission where the lyrics text is a romanized (romaji)
  // transcription instead of the real target-language script — most visibly for Japanese
  // songs. That's a different (wrong) submission, not a language choice this app should just
  // accept: scrolling English-letter "pronunciation" as the 원문 defeats the whole point of
  // the 원문/독음 split (and JapaneseDetector.isJapanese never sees any kana to trigger the
  // 독음 tier on, so it would otherwise silently degrade to 2-tier with the wrong original).
  // Four independent signals, any one enough to reject the candidate:
  //  1. Query title — the *notification's own* title already has kana in it (e.g. "テトリス -
  //     Tetoris"), which is about as direct a signal as this gets: whatever the record itself
  //     looks like, the song we're actually trying to match is Japanese. Checked first since
  //     it needs no guessing at all, unlike 2-4 below.
  //  2. Self-consistency — the record's own trackName/artistName are in Japanese (kana), but
  //     its lyrics field isn't. Needs no assumption about what script the *query* used either.
  //  3. Content shape — some submissions are romanized end-to-end (trackName/artistName *and*
  //     lyrics all in Latin script, e.g. Kenshi Yonezu's "Lemon"), where 1-2 have nothing to
  //     compare against — JapaneseDetector.looksLikeRomanizedJapanese catches those directly
  //     from the lyrics text's own phonetic shape instead.
  //  4. Artist name shape — for when even the query title/artist are already fully romanized
  //     with no kana or distinctive Japanese particles anywhere (e.g. HIMEHINA's "Lemonade",
  //     whose lyrics are genuinely almost all English) — JapaneseDetector.looksLikeJapaneseName
  //     catches those from the artist name's own phonetic shape instead.
  bool _isRomanizedMismatch(Map<String, dynamic> result, String queryTitle, String queryArtist) {
    final syncedLyrics = result['syncedLyrics'] as String?;
    final lyrics = (syncedLyrics?.trim().isNotEmpty ?? false)
        ? syncedLyrics!
        : (result['plainLyrics'] as String? ?? '');
    if (lyrics.trim().isEmpty || JapaneseDetector.isJapanese(lyrics)) {
      return false; // empty, or already has real kana — nothing to flag
    }
    if (JapaneseDetector.isJapanese(queryTitle)) return true;
    final recordTitle = (result['trackName'] as String?) ?? '';
    final recordArtist = (result['artistName'] as String?) ?? '';
    final recordIsJapanese =
        JapaneseDetector.isJapanese(recordTitle) || JapaneseDetector.isJapanese(recordArtist);
    return recordIsJapanese ||
        JapaneseDetector.looksLikeRomanizedJapanese(lyrics) ||
        JapaneseDetector.looksLikeJapaneseName(queryArtist);
  }

  // Some LRCLIB submissions have production-credit lines (lyricist/composer, sometimes a
  // pasted-in translation note) mixed into the lyrics field itself instead of kept out of it —
  // seen in the wild as "作词 : 米津玄師 → Lời : Yonezu Kenshi" sitting right at the top of an
  // otherwise-normal submission (a contributor pasted in credit lines across several
  // languages). That's not just one bad line to skip: this app's own per-line language
  // classifier has no way to know "this line is an out-of-place annotation, not a lyric" versus
  // a genuinely mixed-language verse, so it tries to run the wrong pipeline over it (e.g.
  // Japanese phonetic conversion over what turned out to be an unrelated-language credit line)
  // and produces garbage. Rejecting the whole submission in favor of a cleaner one (from /get,
  // another /search candidate, or just "not found") is simpler and safer than trying to scrub
  // individual lines out of an already-untrustworthy source.
  static const List<String> _creditNoteMarkers = ['作词', '作曲', '编曲', '프로듀서', '작사가', '작곡가'];
  bool _isContaminatedSubmission(Map<String, dynamic> result) {
    final syncedLyrics = result['syncedLyrics'] as String?;
    final lyrics = (syncedLyrics?.trim().isNotEmpty ?? false)
        ? syncedLyrics!
        : (result['plainLyrics'] as String? ?? '');
    if (lyrics.isEmpty) return false;
    return _creditNoteMarkers.any(lyrics.contains);
  }

  // /get matches the artist string server-side (unlike /search, whose results this class
  // filters itself with _artistMatches), so a known alias only helps here if it's actually
  // sent as its own request — checking the *response* against the alias table would be too
  // late, since LRCLIB already 404'd before we ever see a response to check.
  Future<LrclibLyrics?> _getExactWithAlias(
    String trackName,
    String artistName,
    int? durationSeconds,
  ) async {
    final aliases = _artistAliasesFor(artistName);
    if (aliases.isEmpty) return _getExact(trackName, artistName, durationSeconds);
    final results = await Future.wait([
      _getExact(trackName, artistName, durationSeconds),
      for (final alias in aliases) _getExact(trackName, alias, durationSeconds),
    ]);
    // The first hit with sync wins outright — among several spellings of the same artist
    // there's no reason to prefer one script's submission over another's once both are known
    // to be the same real artist, so this doesn't bother comparing them any further.
    for (final result in results) {
      if (result != null && result.hasSyncedLyrics) return result;
    }
    return results.firstWhere((r) => r != null, orElse: () => null);
  }

  Future<LrclibLyrics?> _getExact(String trackName, String artistName, int? durationSeconds) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/get', queryParameters: {
        'track_name': trackName,
        'artist_name': artistName,
        'duration': ?durationSeconds,
      });
      final data = response.data!;
      if (_isRomanizedMismatch(data, trackName, artistName)) return null;
      if (_isContaminatedSubmission(data)) return null;
      return _parse(data);
    } on DioException {
      return null; // 404, network error, or timeout — all "not found for now", not fatal
    }
  }

  Future<List<Map<String, dynamic>>> _search(String trackName, String artistName) async {
    try {
      final response = await _dio.get<List<dynamic>>('/search', queryParameters: {
        'track_name': trackName,
        'artist_name': ?artistName.isEmpty ? null : artistName,
      });
      return (response.data ?? const []).cast<Map<String, dynamic>>();
    } on DioException {
      return const [];
    }
  }

  static final RegExp _tokenPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  // Plain character-level similarity penalizes word-order swaps and added/dropped words
  // harshly (e.g. "Kenshi Yonezu" vs "Yonezu Kenshi"). Comparing as a bag of words instead
  // catches those directly. Used only by fetchLooseLyrics()'s deliberately loose artist check
  // and by _titleCandidates()'s "don't send the artist name itself as a title candidate"
  // filter — the main exact-match search path above doesn't use fuzzy similarity at all.
  double _tokenSimilarity(String a, String b) {
    final tokensA = _tokenPattern.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toSet();
    final tokensB = _tokenPattern.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toSet();
    if (tokensA.isEmpty || tokensB.isEmpty) return 0;
    final intersection = tokensA.intersection(tokensB).length;
    final union = tokensA.union(tokensB).length;
    return intersection / union;
  }

  /// The better of character-level and token-level similarity — takes whichever signal
  /// recognizes the two names as the same artist. Only used by fetchLooseLyrics()'s
  /// deliberately loose fallback.
  double _artistSimilarity(String a, String b) {
    final charSim = _similarity(a, b);
    final tokenSim = _tokenSimilarity(a, b);
    return charSim > tokenSim ? charSim : tokenSim;
  }

  /// 1 - normalized Levenshtein distance, case/whitespace-insensitive.
  double _similarity(String a, String b) {
    final normalizedA = a.toLowerCase().trim();
    final normalizedB = b.toLowerCase().trim();
    if (normalizedA.isEmpty || normalizedB.isEmpty) return 0;
    if (normalizedA == normalizedB) return 1;
    final maxLength = normalizedA.length > normalizedB.length ? normalizedA.length : normalizedB.length;
    return 1 - (_levenshtein(normalizedA, normalizedB) / maxLength);
  }

  int _levenshtein(String a, String b) {
    var previousRow = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final currentRow = List<int>.filled(b.length + 1, 0);
      currentRow[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1;
        currentRow[j] = [
          currentRow[j - 1] + 1, // insertion
          previousRow[j] + 1, // deletion
          previousRow[j - 1] + substitutionCost, // substitution
        ].reduce((x, y) => x < y ? x : y);
      }
      previousRow = currentRow;
    }
    return previousRow[b.length];
  }

  LrclibLyrics _parse(Map<String, dynamic> json) {
    return LrclibLyrics(
      plainLyrics: json['plainLyrics'] as String?,
      syncedLyrics: json['syncedLyrics'] as String?,
      instrumental: json['instrumental'] as bool? ?? false,
    );
  }
}
