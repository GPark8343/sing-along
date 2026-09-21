import 'package:dio/dio.dart';

import '../../core/text/hangul_romanizer.dart';
import '../../core/text/japanese_detector.dart';
import '../../core/text/title_normalizer.dart';

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
    String? featuredArtist,
  }) async {
    final result = await _fetchLyricsOnce(trackName, artistName, durationSeconds, featuredArtist);
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
      featuredArtist,
    );
  }

  Future<LrclibLyrics?> _fetchLyricsOnce(
    String trackName,
    String artistName,
    int? durationSeconds,
    String? featuredArtist,
  ) async {
    // /get and /search don't depend on each other at all, so both fire up front instead of
    // waiting for /get to miss first — LRCLIB's own response time (several seconds per
    // request on a real mobile connection, not milliseconds) makes serializing them a bad
    // trade on every miss, which is the common case (a notification's title/artist rarely
    // matches LRCLIB's own fields closely enough for /get to hit at all).
    final exactFuture = _getExactWithAlias(trackName, artistName, durationSeconds);

    final candidates = _titleCandidates(trackName, artistName);
    final searchFuture =
        _searchExact(candidates, trackName, artistName, durationSeconds, featuredArtist);

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
    ['아키야마 키이로', 'Akiyama Kiiro', 'Kiro Akiyama', '秋山黄色', 'あきやまきいろ'],
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

    // 유명 가수 및 밴드 (singers & bands) - 추가 3 (시티팝, 클래식, 록 밴드 등)
    ['이키모노가카리', 'Ikimonogakari', 'いきものがかり'],
    ['사카낙션', 'Sakanaction', 'サカナクション'],
    ['타케우치 마리야', 'Mariya Takeuchi', '竹内まりや', 'たけうちまりや'],
    ['마츠바라 미키', 'Miki Matsubara', '松原みき', 'まつばらみき'],
    ['미시아', 'MISIA', 'ミーシャ'],
    ['에이토', 'Eito', '瑛人', 'えいと'],
    ['우루', 'Uru', 'ウル'],
    ['다이스', 'Da-iCE', 'ダイス'],
    ['베이비메탈', 'BABYMETAL', 'ベビーメタル'],
    ['호테이 토모야스', 'Tomoyasu Hotei', '布袋寅泰', 'ほていともやす'],
    ['글레이', 'GLAY', 'グレイ'],
    ['루나 씨', 'LUNA SEA', 'ルナシー'],
    ['샤란Q', 'Sharam Q', 'シャ乱Q', 'シャらんキュー'],

    // 우타이테 및 유명 보컬로이드 프로듀서 (utaite & Vocaloid producers) - 추가 3
    ['초가쿠세이 (초학생)', 'Chogakusei', '超学生', 'ちょうがくせい'],
    ['나루세', 'nqrse', 'なるせ'],
    ['리이누', 'Rinu', '莉犬', 'りいぬ'],
    ['루스', 'luz', 'ルス'],
    ['리브', 'Rib', 'りぶ'],
    ['메가테라 제로', 'Megaterra Zero', 'メガテラ・ゼロ'],
    ['게로', 'Gero', 'ゲロ'],
    ['진 (자연의 적P)', 'Jin', 'じん'],
    ['화악기밴드', 'Wagakki Band', '和楽器バンド', 'わがっきバンド'],
    ['하루마키고한', 'Harumaki Gohan', 'はるまきごはん'],
    ['츠미키', 'Tsumiki', 'ツミキ'],

    // 버튜버 (VTubers) - 추가 3 (홀로라이브, 니지산지, 개인세 등)
    ['토키노 소라', 'Tokino Sora', 'ときのそら'],
    ['무라사키 시온', 'Murasaki Shion', '紫咲シオン', 'むらさきシオン'],
    ['아마네 카나타', 'Amane Kanata', '天音かなた', 'あまねかなた'],
    ['오마루 폴카', 'Omaru Polka', '尾丸ポルカ', 'おまるポルカ'],
    ['하쿠이 코요리', 'Hakui Koyori', '博衣こより', 'はくいこより'],
    ['사사키 사쿠', 'Sasaki Saku', '笹木咲', 'ささきさく'],
    ['혼마 히마와리', 'Honma Himawari', '本間ひまわり', 'ほんまひまわり'],
    ['앙쥬 카트리나', 'Ange Katrina', 'アンジュ・カトリーナ'],
    ['리제 헬에스타', 'Lize Helesta', 'リゼ・ヘルエスタ'],
    ['스오우 파트라', 'Suou Patra', '周防パトラ', 'すおうパトラ'],
    ['케이손', 'kson', 'ケイソン'],

    // 보컬로이드 및 음성 합성 소프트웨어 캐릭터 (Vocaloids & SynthV) - 추가 3
    ['시유', 'SeeU', 'シユ'],
    ['오네', 'ONE', 'オネ'],
    ['릴리', 'Lily', 'リリィ'],
    ['SF-A2 미키', 'SF-A2 miki', '開発コード miki', 'みき'],
    ['우타타네 피코', 'Utatane Piko', '歌手音ピコ', 'うたたねピコ'],
    ['하야부사', 'Hayabusa', 'ハヤブサ'],
    ['갸라코', 'galaco', 'ギャラ子', 'ギャラこ'],
    ['메이카 히메', 'Meika Hime', '鳴花ヒメ', 'めいかヒメ'],
    ['메이카 미코토', 'Meika Mikoto', '鳴花ミコト', 'めいかミコト'],

    // 최근 메가 히트곡을 낸 가수 및 밴드 (2020년대 중심)
    ['크리피 넛츠', 'Creepy Nuts', 'クリーピーナッツ'],
    ['오모이노타케', 'Omoinotake', 'オモイノタケ'],
    ['타니 유우키', 'Tani Yuuki', 'タニユウキ'],
    ['아타라시이 각코! (새로운 학교의 리더즈)', 'Atarashii Gakko!', '新しい学校のリーダーズ', 'あたらしいがっこうのリーダーズ'],
    ['스미카', 'sumika', 'スミカ'],
    ['다오코', 'Daoko', 'ダオコ'],

    // 2000년대~2010년대 제이팝 전성기 히트 가수 및 밴드
    ['하마사키 아유미', 'Ayumi Hamasaki', '浜崎あゆみ', 'はまさきあゆみ'],
    ['유이', 'YUI', 'ユイ'],
    ['니시노 카나', 'Kana Nishino', '西野カナ', 'にしのカナ'],
    ['아이코', 'aiko', 'アイコ'],
    ['슈퍼플라이', 'Superfly', 'スーパーフライ'],
    ['유즈', 'Yuzu', 'ゆず'],
    ['오오츠카 아이', 'Ai Otsuka', '大塚愛', 'おおつかあい'],
    ['쿠라키 마이', 'Mai Kuraki', '倉木麻衣', 'くらきまい'],
    ['코부쿠로', 'Kobukuro', 'コブクロ'],
    ['케츠메이시', 'Ketsumeishi', 'ケツメイシ'],

    // 록 밴드 (애니메이션 타이업 등으로 유명한 히트 밴드)
    ['아시안 쿵후 제너레이션', 'ASIAN KUNG-FU GENERATION', 'アジアン・カンフー・ジェネレーション'],
    ['카나분', 'KANA-BOON', 'カナブーン'],
    ['맨 위드 어 미션', 'MAN WITH A MISSION', 'マン・ウィズ・ア・ミッション'],
    ['알렉산드로스', '[Alexandros]', 'アレキサンドロス'],
    ['몽골800', 'MONGOL800', 'モンゴルはっぴゃく'],

    // 레전드 급 국민 가수 및 그룹 (90년대 포함)
    ['스맙', 'SMAP', 'スマップ'],
    ['드림스 컴 트루', 'DREAMS COME TRUE', 'ドリームズ・カム・トゥルー'],
    ['에브리 리틀 씽', 'Every Little Thing', 'エヴリ・リトル・シング'],
    ['티엠 레볼루션', 'T.M.Revolution', 'ティーエムレボリューション'],
    ['야마시타 타츠로', 'Tatsuro Yamashita', '山下達郎', 'やましたたつろう'],
    ['마츠토야 유미', 'Yumi Matsutoya', '松任谷由実', 'まつとうやゆみ'],

    // 아이돌 그룹 (idol groups — 국민적 인기를 끈 그룹)
    ['에이케이비48', 'AKB48', 'エーケービーフォーティーエイト'],
    ['노기자카46', 'Nogizaka46', '乃木坂46', 'のぎざかフォーティーシックス'],
    ['모닝구 무스메', 'Morning Musume', 'モーニング娘。', 'モーニングむすめ'],
    ['스노우 맨', 'Snow Man', 'スノーマン'],
    ['킨키 키즈', 'KinKi Kids', 'キンキキッズ'],
    ['니쥬', 'NiziU', 'ニジュー'],

    // 댄스 & 보컬 그룹 (dance & vocal groups)
    ['에그자일', 'EXILE', 'エグザイル'],
    ['산다이메 제이 소울 브라더스', 'Sandaime J SOUL BROTHERS', '三代目 J SOUL BROTHERS', 'さんだいめジェイ・ソウル・ブラザーズ'],
    ['비퍼스트', 'BE:FIRST', 'ビーファースト'],
    ['미우라 다이치', 'Daichi Miura', '三浦大知', 'みうらだいち'],

    // 솔로 가수 (여성/남성 팝 히트 가수)
    ['캬리 파뮤파뮤', 'Kyary Pamyu Pamyu', 'きゃりーぱみゅぱみゅ'],
    ['코다 쿠미', 'Kumi Koda', '倖田來未', 'こうだくみ'],
    ['쥬쥬', 'JUJU', 'ジュジュ'],
    ['아오이 에이르', 'Eir Aoi', '藍井エイル', 'あおいエイル'],
    ['레오나', 'ReoNa', 'レオナ'],

    // 록 밴드 & 애니메이션 타이업 (rock bands & anime tie-ups)
    ['스파이에어', 'SPYAIR', 'スパイエアー'],
    ['유니즌 스퀘어 가든', 'UNISON SQUARE GARDEN', 'ユニゾンスクエアガーデン'],
    ['플로우', 'FLOW', 'フロウ'],
    ['아쿠아 타임즈', 'Aqua Timez', 'アクアタイムズ'],
    ['스캔달', 'SCANDAL', 'スキャンダル'],
    ['시샤모', 'SHISHAMO', 'シシャモ'],
    ['폴카닷 스팅레이', 'Polkadot Stingray', 'ポルカドットスティングレイ'],

    // 쇼와~헤이세이 시대 전설적인 가수 (80년대~90년대 레전드)
    ['마츠다 세이코', 'Seiko Matsuda', '松田聖子', 'まつだせいこ'],
    ['나카모리 아키나', 'Akina Nakamori', '中森明菜', 'なかもりあきな'],
    ['오자키 유타카', 'Yutaka Ozaki', '尾崎豊', 'おざきゆたか'],
    ['차게 앤 아스카', 'CHAGE and ASKA', 'チャゲ・アンド・アスカ'],
    ['안전지대', 'Anzen Chitai', '安全地帯', 'あんぜんちたい'],
    ['타마키 코지', 'Koji Tamaki', '玉置浩二', 'たまきこうじ'],

    // 최근 틱톡, 릴스 등 숏폼 플랫폼 및 스트리밍 메가 히트 가수
    ['아노', 'ano', 'あの'],
    ['아스미', 'asmi', 'アスミ'],
    ['메종데', 'MAISONdes', 'メゾン・デ'],
    ['워츠', 'WurtS', 'ワーツ'],
    ['콘톤 캔디', 'Conton Candy', 'コントンキャンディ'],
    ['유카', 'YUKA', '有華', 'ゆか'],
    ['토모오', 'TOMOO', 'トモオ'],
    ['리리아.', 'Riria.', 'りりあ。'],
    ['아유무 이마즈', 'Ayumu Imazu', '今津渉', 'いまづあゆむ'],
    ['히라이 다이', 'Dai Hirai', '平井大', 'ひらいだい'],

    // 최근 글로벌 히트 및 대형 팬덤을 가진 보이그룹
    ['넘버 아이', 'Number_i', 'ナンバーアイ'],
    ['스톤즈', 'SixTONES', 'ストーンズ'],
    ['제이오원', 'JO1', 'ジェイオーワン'],
    ['아이엔아이', 'INI', 'アイエヌアイ'],

    // 최근 애니메이션 타이업 및 차트 역주행 히트 밴드/가수
    ['텐피트', '10-FEET', 'テンフィート'],
    ['심', 'SiM', 'シム'],
    ['피플 원', 'PEOPLE 1', 'ピープルワン'],
    ['투보에', 'TOOBOE', 'トオボエ'],
    ['와치', 'wacci', 'ワッチ'],
    ['오썸 시티 클럽', 'Awesome City Club', 'オーサムシティクラブ'],
    ['크로이', 'Kroi', 'クロイ'],
    ['칠리 빈즈', 'Chilli Beans.', 'チリビーンズ'],
    ['널바리치', 'Nulbarich', 'ナルバリッチ'],

    // 최근 힙합/R&B 트렌드 리더
    ['에이위치', 'Awich', 'エイウィッチ'],
    ['시럽', 'SIRUP', 'シラップ'],

    // 보컬로이드 프로듀서 출신이나 틱톡 히트로 대중가수 반열에 오른 아티스트
    ['치노조', 'Chinozo', 'ちのぞー'],

    // 글로벌 애니메이션 타이업 및 하드 록/밴드 트렌드 리더
    ['여왕벌', 'Ziyoou-vachi / Queen Bee', '女王蜂', 'じょおうばち'],
    ['TK from 린토시테시구레', 'TK from Ling tosite sigure', 'TK from 凛として時雨', 'ティーケー・フロム・りんとしてしぐれ'],
    ['밀레니엄 퍼레이드', 'millennium parade', 'ミレニアムパレード'],
    ['버나웃 신드롬즈', 'BURNOUT SYNDROMES', 'バーンアウト・シンドロームズ'],
    ['콜드레인', 'coldrain', 'コールドレイン'],
    ['에고이스트', 'EGOIST', 'エゴイスト'],
    ['슈퍼셀', 'supercell', 'スーパーセル'],
    ['가르니델리아', 'GARNiDELiA', 'ガルニデリア'],
    ['하타 모토히로', 'Motohiro Hata', '秦基博', 'はたもとひろ'],
    ['오이시 마사요시', 'Masayoshi Oishi', '大石昌良', 'おおいしまさよし'],
    ['미즈키 나나', 'Nana Mizuki', '水樹奈々', 'みずきなな'],
    ['클라리스', 'ClariS', 'クラリス'],
    ['스키마스위치', 'Sukima Switch', 'スキマスイッチ'],

    // 인터넷/틱톡 발 팝 아티스트 및 프로듀서
    ['츠유', 'TUYU', 'ツユ'],
    ['와누카', 'Wanuka', '和ぬか', 'わぬか'],
    ['스다 케이나', 'Keina Suda', '須田景凪', 'すだけいな'], // 벌룬(Balloon)의 싱어송라이터 활동명
    ['허니웍스', 'HoneyWorks', 'ハニーワークス'],
    ['3월의 판타시아', 'Sangatsu no Phantasia', '三月のパンタシア', 'さんがつのパンタシア'],
    ['P마루사마', 'P Maru-sama', 'P丸様。', 'ピーまるさま'],
    ['소우', 'Sou', 'ソウ'],

    // 레전드 및 최신 보컬로이드 프로듀서
    ['오와카', 'wowaka', 'ヲワカ'],
    ['칸자키 이오리', 'Kanzaki Iori', 'カンザキイオリ'],
    ['쿠로우사 P', 'Kurousa P', '黒うさP', 'くろうさピー'],
    ['하치오지 P', 'Hachioji P', '八王子P', 'はちおうじピー'],
    ['스리이', 'surii', 'すりぃ'],
    ['아야세', 'Ayase', 'アヤセ'], // YOASOBI의 프로듀서 본인 명의

    // 버추얼 아티스트 및 추가 버튜버 (홀로라이브, 카미츠바키 스튜디오, 1세대 등)
    ['키즈나 아이', 'Kizuna AI', 'キズナアイ'],
    ['리메', 'RIM', '理芽', 'りめ'],
    ['사카마타 클로에', 'Sakamata Chloe', '沙花叉クロヱ', 'さかまたクロヱ'],
    ['오오카미 미오', 'Ookami Mio', '大神ミオ', 'おおかみミオ'],
    ['모모스즈 네네', 'Momosuzu Nene', '桃鈴ねね', 'ももすずねね'],
    ['시로가네 노엘', 'Shirogane Noel', '白銀ノエル', 'しろがねノエル'],
    ['시라누이 후레아', 'Shiranui Flare', '不知火フレア', 'しらぬいフレア'],
    ['카구야 루나', 'Kaguya Luna', '輝夜月', 'かぐやるな'],

    // 인디/얼터너티브, 록, 애니메이션 타이업 밴드 및 가수
    ['게스노키와미오토메', 'Gesu no Kiwami Otome', 'ゲスの極み乙女', 'ゲスのきわみおとめ'],
    ['인디고 라 엔드', 'indigo la End', 'インディゴ ラ エンド'],
    ['맥시멈 더 호르몬', 'MAXIMUM THE HORMONE', 'マキシマム ザ ホルモン'],
    ['비쉬', 'BiSH', 'ビッシュ'],
    ['플룸풀', 'flumpool', 'フランプール'],
    ['미야노 마모루', 'Mamoru Miyano', '宮野真守', 'みやのまもる'],
    ['스피라 스피카', 'Spira Spica', 'スピラ・スピカ'],
    ['아카세 아카리', 'Akari Akase', 'あかせあかり'],
    ['안리', 'Anri', '杏里', 'あんり'],
    ['오메가 트라이브', 'Omega Tribe', 'オメガトライブ'],
    ['키린지', 'KIRINJI', 'キリンジ'],
    ['챤미나', 'CHANMINA', 'ちゃんみな'],
    ['엑스지', 'XG', 'エックスジー'],
    ['야바이 티셔츠 야상', 'Yabai T-Shirt Yasan', 'ヤバイTシャツ屋さん', 'ヤバイティーシャツやさん'],

    // 우타이테 및 유명 보컬로이드 프로듀서 - 추가 4
    ['미키토P', 'MikitoP', 'みきとP', 'みきとピー'],
    ['카이리키 베어', 'Kairiki bear', 'かいりきベア'],
    ['니루카지츠', 'Nilfruits', '煮ル果実', 'にルかじつ'],
    ['쿠라게P', 'KurageP', 'くらげP', 'くらげピー'],
    ['코스모@폭주P', 'cosMo@BousouP', 'cosMo@暴走P', 'コスモ アット ぼうそうピー'],
    ['구치리', 'Guchiry', 'ぐちり'],
    ['유요유페', 'Yuyoyuppe', 'ゆよゆっぺ'],
    ['토마', 'Tohma', 'トーマ'],
    ['피콘', 'Picon', 'ピコン'],
    ['카노', 'Kano', '鹿乃', 'かの'],
    ['구루타밍', 'Glutamine', 'ぐるたみん'],
    ['아라키', 'Araki', 'あらき'],

    // 버튜버 (홀로라이브, 니지산지 소속 및 개인세) - 추가 4
    ['히메모리 루나', 'Himemori Luna', '姫森ルーナ', 'ひめもりルーナ'],
    ['카자마 이로하', 'Kazama Iroha', '風真いろは', 'かざまいろは'],
    ['아키 로젠탈', 'Aki Rosenthal', 'アキ・ローゼンタール'],
    ['로보코 씨', 'Robocosan', 'ロボ子さん', 'ロボこさん'],
    ['왓슨 아멜리아', 'Watson Amelia', 'ワトソン・アメリア'],
    ["니노마에 이나니스", "Ninomae Ina'nis", '一伊那尓栖', 'にのまえいなにす'],
    ['타카나시 키아라', 'Takanashi Kiara', '小鳥遊キアラ', 'たかなしキアラ'],
    ['나나시 무메이', 'Nanashi Mumei', '七詩ムメイ', 'ななしムメイ'],
    ['오로 크로니', 'Ouro Kronii', 'オーロ・クロニー'],
    ['코보 카나에루', 'Kobo Kanaeru', 'こぼ・かなえる'],
    ['복스 아쿠마', 'Vox Akuma', 'ヴォックス・アクマ'],
    ['미스타 리아스', 'Mysta Rias', 'ミスタ・リアス'],
    ['아이바 우이하', 'Aiba Uiha', '相羽ういは', 'あいばういは'],
    ['시구레 우이', 'Ui Shigure', 'しぐれうい'],

    // 보컬로이드 및 음성 합성 캐릭터 (Vocaloids & SynthV) - 추가 4
    ['키즈나 아카리', 'Kizuna Akari', '紲星あかり', 'きずなあかり'],
    ['치카', 'Chika', 'チカ'],
    ['라나', 'Rana', 'ラナ'],
    ['코코네', 'Kokone', '心華', 'ここね'],
    ['사토 사사라', 'Sato Sasara', 'さとうささら'],
    ['스즈키 츠두미', 'Suzuki Tsudumi', 'すずきつづみ'],
    ['엘리노어 포르테', 'Eleanor Forte', 'エレノア・フォルテ'],
    ['루이', 'Lui', 'ルイ'],
    ['링', 'Ring', 'リング'],

    // 최근 숏폼/스트리밍 메가 히트 가수
    ['에일', 'eill', 'エイル'],
    ['콧치노 켄토', 'Kocchi no Kento', 'こっちのけんと'],
    ['츠키', 'tuki.', 'ツキ'],
    ['타카얀', 'Takayan', 'たかやん'],
    ['모사오', 'Mosawo.', 'もさを。'],
    ['초큐메이', 'ChoQMay', 'チョーキューメイ'],
    ['코하나 람', 'Kohana Lam', 'こはならむ'],
    ['린네', 'Rin音', 'りんね'],

    // eill과 비슷한 바이브의 R&B, 소울, 힙합, 트렌디 팝 아티스트
    ['이리', 'iri', 'イリ'],
    ['무카이 타이치', 'Taichi Mukai', '向井太一', 'むかいたいち'],
    ['첼미코', 'chelmico', 'チェルミコ'],
    ['스터츠', 'STUTS', 'スタッツ'],
    ['펀피', 'PUNPEE', 'パンピー'],
    ['오부쿠로 나리아키', 'Nariaki Obukuro', '小袋成彬', 'おぶくろなりあき'],
    ['스카이하이', 'SKY-HI', 'スカイハイ'],
    ['치바 유키 (코)', 'Yuki Chiba (KOHH)', '千葉雄喜', 'ちばゆうき'],
    ['신 사키우라', 'Shin Sakiura', 'シン・サキウラ'],

    // 떠오르는 싱어송라이터 및 록/인디 팝
    ['비케블랑카', 'Vickeblanka', 'ビッケブランカ'],
    ['코레사와', 'Koresawa', 'コレサワ'],
    ['미유나', 'Miyuna', 'みゆな'],
    ['안리 (Anly)', 'Anly', 'アンリ'],
    ['시유이', 'Shiyui', 'シユイ'],
    ['렌', 'ReN', 'レン'],
    ['카미와 사이코로오 후라나이 (신은 주사위를 던지지 않는다)', 'Kami wa Saikoro wo Furanai', '神はサイコロを振らない', 'かみはサイコロをふらない'],
    ['칸카쿠 피에로', 'Kankaku Piero', '感覚ピエロ', 'かんかくピエロ'],
    ['사죠노하나', 'sajou no hana', 'サジョウノハナ'],

    // 인터넷 일렉트로닉 팝 및 트랙메이커 (서브컬처 친화적)
    ['테디로이드', 'TeddyLoid', 'テディロイド'],
    ['유노미', 'Yunomi', 'ユノミ'],
    ['네코 해커', 'Neko Hacker', 'ネコハッカー'],
    ['코토노하우스', 'KOTONOHOUSE', 'コトノハウス'],

    // 버튜버 (인기 스트리머 및 브이스포/네오포르테 계열)
    ['시부야 할', 'Shibuya HAL', '渋谷ハル', 'しぶやハル'],
    ['시라유키 레이드', 'Shirayuki Reid', '白雪レイド', 'しらゆきレイド'],
    ['쿠루미 노아', 'Kurumi Noah', '胡桃のあ', 'くるみのあ'],
    ['이치노세 우루하', 'Ichinose Uruha', '一ノ瀬うるは', 'いちのせうるは'],
    ['시시가미 레오나', 'Shishigami Leona', '獅子神レオナ', 'ししがみレオナ'],

    // 최근 틱톡/릴스 등 숏폼 및 스트리밍 메가 히트 가수 (싱어송라이터 및 프로듀서)
    ['메이요', 'meiyo', 'メイヨー'],
    ['쿠지라', 'Kujira', 'くじら'],
    ['카와사키 타카야', 'Takaya Kawasaki', '川崎鷹也', 'かわさきたかや'],
    ['오하시 치포케', 'Chippoke Ohashi', '大橋ちっぽけ', 'おおはしちっぽけ'],
    ['히구치 아이', 'Ai Higuchi', 'ヒグチアイ'],
    ['나키무시', 'Nakimushi', '泣き虫', 'なきむし'],
    ['클랑 룰러', 'Klang Ruler', 'クラングルーラー'],
    ['헨타이 신사 클럽', 'HENTAI SHINSHI CLUB', '変態紳士クラブ', 'へんたいしんしクラブ'],
    ['보쿠노 리릭노 보이요미', 'Boku no Lyric no Boyomi', 'ぼくのりりっくのぼうよみ'],
    ['디오스', 'Dios', 'ディオス'],

    // 틱톡 댄스 챌린지 및 숏폼 메가 히트 아이돌/가수
    ['후르츠 지퍼', 'FRUITS ZIPPER', 'フルーツジッパー'],
    ['초 도키메키 센덴부', 'Cho Tokimeki Sendenbu', '超ときめき♡宣伝部', 'ちょうときめきせんでんぶ'],
    ['타카네노 나데시코', 'Takane no Nadeshiko', '高嶺のなでしこ', 'たかねのなでしこ'],
    ['모모이로 클로버 Z', 'Momoiro Clover Z', 'ももいろクローバーZ', 'ももいろクローバーゼット'],
    ['와다 아키코', 'Akiko Wada', '和田アキ子', 'わだあきこ'], // 'YONA YONA DANCE' 숏폼 메가 히트
    ['마츠다이라 켄', 'Ken Matsudaira', '松平健', 'まつだいらけん'], // '마츠켄 삼바' 밈/역주행 히트

    // R&B, 힙합, 시티팝 트렌드를 이끄는 아티스트
    ['서치모스', 'Suchmos', 'サチモス'],
    ['럭키 킬리만자로', 'Lucky Kilimanjaro', 'ラッキーキリマンジャロ'],
    ['나카무라 카호', 'Kaho Nakamura', '中村佳穂', 'なかむらかほ'],
    ['토지', 'Tohji', 'トージ'],
    ['우메다 사이퍼', 'Umeda Cypher', '梅田サイファー', 'うめだサイファー'],
    ['템파레이', 'Tempalay', 'テンパレイ'],
    ['세로', 'cero', 'セロ'],
    ['루드 알파', 'Rude-α', 'ルードアルファ'],

    // 밀리언셀러 및 록, 펑크, 대중 밴드 (역주행 및 틱톡 BGM 포함)
    ['오렌지 렌지', 'ORANGE RANGE', 'オレンジレンジ'],
    ['쇼난노카제', 'Shonan no Kaze', '湘南乃風', 'しょうなんのかぜ'],
    ['데프 테크', 'Def Tech', 'デフテック'],
    ['포 리미티드 사자비스', '04 Limited Sazabys', 'フォー・リミテッド・サザビーズ'],
    ['서바이브 세드 더 프로펫', 'Survive Said The Prophet', 'サバイブ・セッド・ザ・プロフェット'],
    ['크로스페이스', 'Crossfaith', 'クロスフェイス'],
    ['오이시쿠루 메론빵', 'Oisicle Melonpan', 'おいしくるメロンパン'],
    ['모시모', 'MOSHIMO', 'モシモ'],

    // 인터넷/유튜브 기반 활동 가수 및 버추얼 싱어 (카미츠바키 스튜디오 등)
    ['다즈비', 'Dazbee', 'ダズビー'],
    ['라온', 'Raon', 'ラオン'],
    ['이세계정서', 'Isekaijoucho', 'ヰ世界情緒', 'いせかいじょうちょ'],
    ['하루사루히', 'Harusaruhi', '春猿火', 'はるさるひ'],
    ['코코', 'Koko', '幸祜', 'ここ'],
    ['발리스', 'VALIS', 'ヴァリス'],
    ['모에 숍', 'Moe Shop', 'モエショップ'],

    // 사와노 히로유키(Sawano Hiroyuki) 및 SawanoHiroyuki[nZk] 주요 객원 보컬
    ['사와노 히로유키', 'Hiroyuki Sawano', '澤野弘之', 'さわのひろゆき'],
    ['코바야시 미카', 'Mika Kobayashi', '小林未郁', 'こばやしみか'],
    ['엠피아이', 'mpi', 'エムピーアイ'],
    ['제미', 'Gemie', 'ジェミー'],
    ['요시', 'Yosh', 'ヨシ'],
    ['에이미 블랙슐레거', 'Aimee Blackschleger', 'エイミー・ブラックシュレガー'],
    ['라코', 'Laco', 'ラコ'],
    ['센나린', 'SennaRin', 'センナリン'],

    // 진격의 거인(Attack on Titan) 애니메이션 역대 주제가(OP/ED) 아티스트
    ['링크드 호라이즌', 'Linked Horizon', 'リンクトホライズン'],
    ['신세이카맛테찬', 'Shinsei Kamattechan', '神聖かまってちゃん', 'しんせいかまってちゃん'],
    ['안도 유코', 'Yuko Ando', '安藤裕子', 'あんどうゆうこ'],
    ['히카사 요코', 'Yoko Hikasa', '日笠陽子', 'ひかさようこ'],
    ['시네마 스태프', 'cinema staff', 'シネマスタッフ'],
    ['요시키', 'YOSHIKI', 'ヨシキ'],
    ['하이드', 'HYDE', 'ハイド'],

    // 전설적인 클래식 애니송 및 특촬 가수
    ['타카하시 요코', 'Yoko Takahashi', '高橋洋子', 'たかはしようこ'],
    ['와다 코지', 'Koji Wada', '和田光司', 'わだこうじ'],
    ['미야자키 아유미', 'Ayumi Miyazaki', '宮崎歩', 'みやざきあゆみ'],
    ['키타다니 히로시', 'Hiroshi Kitadani', 'きただにひろし'],
    ['하야시바라 메구미', 'Megumi Hayashibara', '林原めぐみ', 'はやしばらめぐみ'],
    ['사사키 이사오', 'Isao Sasaki', 'ささきいさお', '佐々木功'],
    ['미즈키 이치로', 'Ichiro Mizuki', '水木一郎', 'みずきいちろう'],

    // 독보적 세계관의 애니메이션 음악 작곡가 및 음악 유닛
    ['카지우라 유키', 'Yuki Kajiura', '梶浦由記', 'かじうらゆき'],
    ['픽션정션', 'FictionJunction', 'フィクションジャンクション'],
    ['카라피나', 'Kalafina', 'カラフィナ'],
    ['칸노 요코', 'Yoko Kanno', '菅野よう子', 'かんのようこ'],
    ['안젤라', 'angela', 'アンジェラ'],
    ['알리 프로젝트', 'ALI PROJECT', 'アリ・プロジェクト'],
    ['알리', 'ALI', 'アリ'],
    ['미스 앤드 로이드', 'MYTH & ROID', 'ミスアンドロイド'],
    ['옥트', 'OxT', 'オクト'],
    ['파나', 'fhána', 'ファナ'],

    // I've Sound 계열 및 일렉트로닉 팝 애니송 아티스트
    ['프립사이드', 'fripSide', 'フリップサイド'],
    ['코토코', 'KOTOKO', 'コトコ'],
    ['카와다 마미', 'Mami Kawada', '川田まみ', 'かわだまみ'],
    ['엘리사', 'ELISA', 'エリサ'],

    // 대표적인 애니메이션 주제가 전문 싱어송라이터
    ['야나기나기', 'yanaginagi', 'やなぎなぎ'],
    ['쵸쵸', 'ChouCho', 'ちょうちょ'],
    ['나노', 'nano', 'ナノ'],
    ["메인", "May'n", 'メイン'],
    ['나카지마 메구미', 'Megumi Nakajima', '中島愛', 'なかじまめぐみ'],
    ['두 애즈 인피니티', 'Do As Infinity', 'ドゥ・アズ・インフィニティ'],
    ['스즈키 마사유키', 'Masayuki Suzuki', '鈴木雅之', 'すずきまさゆき'],
    ['할카', 'halca', 'ハルカ'],
    ['레이', 'Ray', 'レイ'],
    ['츠치야 안나', 'Anna Tsuchiya', '土屋アンナ', 'つちやアンナ'],
    ['올리비아', 'OLIVIA', 'オリビア'],

    // 록 / 남성 보컬 중심 애니메이션 타이업 유닛 및 밴드
    ['그란로데오', 'GRANRODEO', 'グランロデオ'],
    ['올드코덱스', 'OLDCODEX', 'オールドコーデックス'],

    // 정상급 인기 성우 겸 솔로 아티스트
    ['치하라 미노리', 'Minori Chihara', '茅原実里', 'ちはらみのり'],
    ['히라노 아야', 'Aya Hirano', '平野綾', 'ひらのあや'],
    ['하나자와 카나', 'Kana Hanazawa', '花澤香菜', 'はなざわかな'],
    ['미나세 이노리', 'Inori Minase', '水瀬いのり', 'みなせいのり'],
    ['하야미 사오리', 'Saori Hayami', '早見沙織', 'はやみさおり'],
    ['우치다 마아야', 'Maaya Uchida', '内田真礼', 'うちだまあや'],
    ['아마미야 소라', 'Sora Amamiya', '雨宮天', 'あまみやそら'],
    ['트라이세일', 'TrySail', 'トライセイル'],
    ['오구라 유이', 'Yui Ogura', '小倉唯', 'おぐらゆい'],
    ['쿠스노키 토모리', 'Tomori Kusunoki', '楠木ともり', 'くすのきともり'],
    ['사이토 소마', 'Soma Saito', '斉藤壮馬', 'さいとうそうま'],
    ['우치다 유우마', 'Yuma Uchida', '内田雄馬', 'うちだゆうま'],

    // 대형 애니메이션 프로젝트 공식 밴드 및 유닛
    ['결속밴드', 'Kessoku Band', '結束バンド', 'けっそくバンド'],
    ["뮤즈", "μ's", 'ミューズ'],
    ['아쿠아', 'Aqours', 'アクア'],
    ["팝핀파티", "Poppin'Party", 'ポッピンパーティー'],
    ['로젤리아', 'Roselia', 'ロゼリア'],
    ['레이즈 어 스이렌', 'RAISE A SUILEN', 'レイズ・ア・スイレン'],
    ['마이고', 'MyGO!!!!!', 'マイゴ'],
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
    String? featuredArtist,
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
        if (normalizedArtist.isNotEmpty &&
            !_artistOk(normalizedArtist, entryArtist, featuredArtist)) {
          continue;
        }
        if (_isRomanizedMismatch(entry, trackName, artistName)) continue;
        if (_isContaminatedSubmission(entry)) continue;
        best = _preferred(best, entry, durationSeconds, featuredArtist);
      }
    }
    return best == null ? null : _parse(best);
  }

  // Among multiple exact title/artist matches (different contributors' submissions of the
  // same recording), prefers a synced one over a plain one; then, if a "(feat. X)" clause was
  // in the query, one whose own trackName/artistName actually credits that guest over one that
  // doesn't (LRCLIB submissions are inconsistent about this — some credit only the primary
  // artist even for the same recording — so a submission that *does* name the featured artist
  // is more confidently the exact right recording, not just a same-title/artist match); and
  // finally, among ties, whichever duration is closer to the one actually playing, so a studio
  // cut doesn't get mixed up with a live/extended version sharing the same title and artist.
  Map<String, dynamic> _preferred(
    Map<String, dynamic>? current,
    Map<String, dynamic> candidate,
    int? durationSeconds,
    String? featuredArtist,
  ) {
    if (current == null) return candidate;
    final currentSynced = (current['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false;
    final candidateSynced = (candidate['syncedLyrics'] as String?)?.trim().isNotEmpty ?? false;
    if (candidateSynced != currentSynced) return candidateSynced ? candidate : current;
    if (featuredArtist != null && featuredArtist.isNotEmpty) {
      final currentHasFeature = _mentionsArtist(current, featuredArtist);
      final candidateHasFeature = _mentionsArtist(candidate, featuredArtist);
      if (candidateHasFeature != currentHasFeature) {
        return candidateHasFeature ? candidate : current;
      }
    }
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
    if (lyrics.trim().isEmpty || _looksProperlyJapanese(lyrics)) {
      return false; // empty, or genuinely Japanese-scripted throughout — nothing to flag
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

  // A single scattered kana character anywhere in the whole blob used to be enough to call a
  // submission "already Japanese-scripted" — but some contributors submit a mostly-romanized
  // transcription with one stray line transcribed in kana (an ad-lib/backing-vocal line, seen
  // in the wild on Ado's "AiAiA": 14 romaji lines and exactly one real-kana line), which that
  // single whole-text check waved through as fine. Requiring a majority of non-empty lines to
  // contain kana instead means an isolated kana line can no longer vouch for an otherwise
  // fully-romanized submission.
  bool _looksProperlyJapanese(String lyrics) {
    final lines = lyrics.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return false;
    final kanaLines = lines.where(JapaneseDetector.isJapanese).length;
    return kanaLines / lines.length >= 0.5;
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

  // Whether `name` shows up in this result's own trackName or artistName — used both to widen
  // artist acceptance (_artistOk below) and as a preference signal (_preferred above) for a
  // "(feat. X)" query, never as an outright rejection: LRCLIB submissions are inconsistent
  // about whether a featured artist is credited at all (plenty of correct, single-artist-only
  // submissions exist for a song that does have a real feature — see Camila Cabello's
  // "Havana"), so demanding it be present would reject perfectly good matches just as often as
  // it would catch a genuinely wrong one.
  bool _mentionsArtist(Map<String, dynamic> result, String name) {
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return false;
    final title = ((result['trackName'] as String?) ?? '').toLowerCase();
    final artist = ((result['artistName'] as String?) ?? '').toLowerCase();
    return title.contains(needle) || artist.contains(needle);
  }

  // The exact-match artist check above rejects "Camila Cabello feat. Young Thug" outright for
  // a query artist of plain "Camila Cabello" — not the same string at all, even though it's
  // the same artist, just with a collaborator's credit folded into the same field the way some
  // contributors submit it. Stripping that clause the same way TitleNormalizer.primaryArtist()
  // already does for the *query* side and comparing what's left recognizes these as a match
  // too, but only when the featured name we're actually looking for is the one credited —
  // otherwise a random other collab ("... feat. Someone Else") would wrongly pass as well.
  bool _artistOk(String normalizedArtist, String entryArtist, String? featuredArtist) {
    if (_artistMatches(normalizedArtist, entryArtist)) return true;
    if (featuredArtist == null || featuredArtist.isEmpty) return false;
    final entryPrimary = TitleNormalizer.primaryArtist(entryArtist).trim().toLowerCase();
    if (!_artistMatches(normalizedArtist, entryPrimary)) return false;
    return entryArtist.contains(featuredArtist.trim().toLowerCase());
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
    if (aliases.isEmpty) {
      return _getExact(trackName, artistName, durationSeconds);
    }
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

  // No featuredArtist check here — /get is matched server-side against whatever artistName we
  // actually send, which is always the plain primary artist (never the feat-augmented string),
  // so its response is never going to be one of the "feat. X credited in the artist field"
  // submissions _artistOk()/_preferred() above specifically watch for. Rejecting a plain-
  // artist /get hit just for not mentioning a feature it was never going to mention would only
  // throw away a perfectly good match.
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
