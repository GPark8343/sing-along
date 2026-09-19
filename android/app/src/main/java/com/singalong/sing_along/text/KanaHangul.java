package com.singalong.sing_along.text;

import java.util.HashMap;
import java.util.Map;

/**
 * Deterministic kana -> Hangul transliteration (a Korean "phonetic reading" of Japanese kana):
 * one kana (or youon combo) always maps to the same Hangul syllable, no positional or
 * part-of-speech-dependent exceptions. Runs entirely offline: no network call, so it can't be
 * interrupted by Android's background process freeze the way the old Claude-based pipeline could
 * be (see JapaneseReadingHandler).
 *
 * An earlier version tried to follow the official 외래어 표기법 more closely — word-initial
 * lenition for か/た (가케루 vs 카케루) and a no-glide exception for ち/じ (차 instead of 챠) — but
 * that made the output inconsistent and unpredictable in practice (동일한 か가 문맥에 따라 다르게
 * 나옴), so this sticks to one mapping per kana throughout.
 */
final class KanaHangulTables {
    private KanaHangulTables() {}

    static final Map<String, String> TABLE = new HashMap<>();

    private static void put(String kana, String hangul) {
        TABLE.put(kana, hangul);
    }

    static {
        // Vowels
        put("ア", "아"); put("イ", "이"); put("ウ", "우"); put("エ", "에"); put("オ", "오");

        // か行
        put("カ", "카"); put("キ", "키"); put("ク", "쿠"); put("ケ", "케"); put("コ", "코");
        put("キャ", "캬"); put("キュ", "큐"); put("キョ", "쿄");
        // が行
        put("ガ", "가"); put("ギ", "기"); put("グ", "구"); put("ゲ", "게"); put("ゴ", "고");
        put("ギャ", "갸"); put("ギュ", "규"); put("ギョ", "교");

        // さ/ざ行
        put("サ", "사"); put("シ", "시"); put("ス", "스"); put("セ", "세"); put("ソ", "소");
        put("シャ", "샤"); put("シュ", "슈"); put("ショ", "쇼"); put("シェ", "셰");
        put("ザ", "자"); put("ジ", "지"); put("ズ", "즈"); put("ゼ", "제"); put("ゾ", "조");
        put("ジャ", "쟈"); put("ジュ", "쥬"); put("ジョ", "죠"); put("ジェ", "제");

        // た行
        put("タ", "타"); put("チ", "치"); put("ツ", "츠"); put("テ", "테"); put("ト", "토");
        put("チャ", "챠"); put("チュ", "츄"); put("チョ", "쵸"); put("チェ", "체");
        // だ行
        put("ダ", "다"); put("ヂ", "지"); put("ヅ", "즈"); put("デ", "데"); put("ド", "도");
        put("ヂャ", "쟈"); put("ヂュ", "쥬"); put("ヂョ", "죠");

        // な行
        put("ナ", "나"); put("ニ", "니"); put("ヌ", "누"); put("ネ", "네"); put("ノ", "노");
        put("ニャ", "냐"); put("ニュ", "뉴"); put("ニョ", "뇨");

        // は/ば/ぱ行
        put("ハ", "하"); put("ヒ", "히"); put("フ", "후"); put("ヘ", "헤"); put("ホ", "호");
        put("ヒャ", "햐"); put("ヒュ", "휴"); put("ヒョ", "효");
        put("バ", "바"); put("ビ", "비"); put("ブ", "부"); put("ベ", "베"); put("ボ", "보");
        put("ビャ", "뱌"); put("ビュ", "뷰"); put("ビョ", "뵤");
        put("パ", "파"); put("ピ", "피"); put("プ", "푸"); put("ペ", "페"); put("ポ", "포");
        put("ピャ", "퍄"); put("ピュ", "퓨"); put("ピョ", "표");

        // ま行
        put("マ", "마"); put("ミ", "미"); put("ム", "무"); put("メ", "메"); put("モ", "모");
        put("ミャ", "먀"); put("ミュ", "뮤"); put("ミョ", "묘");

        // や/ら/わ行
        put("ヤ", "야"); put("ユ", "유"); put("ヨ", "요");
        put("ラ", "라"); put("リ", "리"); put("ル", "루"); put("レ", "레"); put("ロ", "로");
        put("リャ", "랴"); put("リュ", "류"); put("リョ", "료");
        put("ワ", "와"); put("ヲ", "오"); put("ヴ", "부");

        // Extended katakana for English loanwords, common in J-pop lyrics — these are
        // two-character combos with a small vowel (ァィゥェォ), not a small ya/yu/yo, so they
        // need isSmallKana() below to recognize ィ etc. as combo-forming too, or the lookup
        // above never even tries the two-character key.
        put("ファ", "파"); put("フィ", "피"); put("フェ", "페"); put("フォ", "포");
        put("ティ", "티"); put("トゥ", "투"); put("ディ", "디"); put("ドゥ", "두");
        put("ウィ", "위"); put("ウェ", "웨"); put("ウォ", "워");
        put("ヴァ", "바"); put("ヴィ", "비"); put("ヴェ", "베"); put("ヴォ", "보");
        put("クァ", "콰"); put("クィ", "퀴"); put("クェ", "퀘"); put("クォ", "쿼");
        put("グァ", "과");
        put("ツァ", "차"); put("ツィ", "치"); put("ツェ", "체"); put("ツォ", "초");

        // Standalone small vowels — a fallback for any two-character combo above that isn't in
        // this table (an uncommon loanword sound), so at worst it renders as an extra syllable
        // rather than leaking the raw katakana character into the output.
        put("ァ", "아"); put("ィ", "이"); put("ゥ", "우"); put("ェ", "에"); put("ォ", "오");
    }
}

public final class KanaHangul {
    private KanaHangul() {}

    private static final int HANGUL_BASE = 0xAC00;
    private static final int JONGSEONG_COUNT = 28;
    private static final int JONGSEONG_NIEUN = 4; // ㄴ
    private static final int JONGSEONG_SIOT = 19; // ㅅ

    /**
     * Appends one kuromoji token's reading (expected in katakana, as kuromoji-ipadic returns it)
     * to [out] as Korean Hangul. Takes the running buffer for the *whole line* rather than
     * starting fresh per token — ん/っ attach a batchim onto whatever syllable was last written,
     * which needs to reach across token boundaries: ん very commonly shows up as its own token
     * (casual sentence-final nominalizer, e.g. 行くんだ), and transliterating it in isolation
     * left it with nothing to attach to, silently dropping it.
     */
    public static void appendTransliteration(StringBuilder out, String reading) {
        if (reading == null || reading.isEmpty()) return;
        String normalized = toKatakana(reading);
        int i = 0;
        int n = normalized.length();
        while (i < n) {
            char c = normalized.charAt(i);
            if (c == 'ー') {
                i++;
                continue; // long vowel mark: not written separately
            }
            if (c == 'ッ') {
                appendBatchim(out, JONGSEONG_SIOT);
                i++;
                continue;
            }
            if (c == 'ン') {
                appendBatchim(out, JONGSEONG_NIEUN);
                i++;
                continue;
            }
            String mora;
            int consumed;
            if (i + 1 < n && isSmallKana(normalized.charAt(i + 1))) {
                String two = normalized.substring(i, i + 2);
                if (KanaHangulTables.TABLE.containsKey(two)) {
                    mora = two;
                    consumed = 2;
                } else {
                    mora = normalized.substring(i, i + 1);
                    consumed = 1;
                }
            } else {
                mora = normalized.substring(i, i + 1);
                consumed = 1;
            }
            String hangul = KanaHangulTables.TABLE.get(mora);
            if (hangul != null) {
                out.append(hangul);
            } else if (!(mora.length() == 1 && isHanCharacter(mora.charAt(0)))) {
                // Kept as-is: an unmapped kana (incomplete table coverage) still reads as
                // Japanese, and a stray ASCII/Latin word embedded in the line is already
                // readable verbatim — neither needs to be dropped just because it has no
                // Hangul mapping.
                out.append(mora);
            }
            // Omitted: a kanji character lands here when kuromoji couldn't produce a reading
            // for its token and JapaneseReadingHandler fell back to the raw surface text (see
            // readingOf() there) — appending that unconverted kanji would leak untranslated Han
            // characters into what's supposed to be a Korean phonetic reading, reading as
            // stray Chinese text to anyone who can't tell kanji from hanzi at a glance. Omitting
            // it from this line is more honest than showing something wrong.
            i += consumed;
        }
    }

    // CJK Unified Ideographs (kanji) — deliberately not "any non-Latin script", since kana
    // (already handled above) and full-width punctuation/symbols that can show up in lyrics
    // should still pass through unchanged; this only needs to catch actual kanji.
    private static boolean isHanCharacter(char c) {
        return (c >= 0x4E00 && c <= 0x9FFF) // CJK Unified Ideographs
                || (c >= 0x3400 && c <= 0x4DBF) // CJK Extension A
                || (c >= 0xF900 && c <= 0xFAFF); // CJK Compatibility Ideographs
    }

    // Small kana that can combine with a preceding consonant kana into one two-character mora:
    // ゃゅょ for youon (きゃ etc.) and ぁぃぅぇぉ for the extended loanword combos (てぃ, ふぉ, ...).
    private static boolean isSmallKana(char c) {
        switch (c) {
            case 'ャ': case 'ュ': case 'ョ': case 'ゃ': case 'ゅ': case 'ょ':
            case 'ァ': case 'ィ': case 'ゥ': case 'ェ': case 'ォ':
            case 'ぁ': case 'ぃ': case 'ぅ': case 'ぇ': case 'ぉ':
                return true;
            default:
                return false;
        }
    }

    // Hiragana and katakana share the same relative layout offset by 0x60 for the common
    // range, so normalizing to katakana lets the table above only need one script's worth of
    // entries — this matters because kuromoji-ipadic returns readings in katakana, but the
    // surface text fallback (used when a token has no analyzable reading) is often hiragana.
    private static String toKatakana(String text) {
        StringBuilder sb = new StringBuilder(text.length());
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c >= 0x3041 && c <= 0x3096) {
                sb.append((char) (c + 0x60));
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    private static void appendBatchim(StringBuilder out, int jongseongIndex) {
        if (out.length() == 0) return;
        int lastPos = out.length() - 1;
        char last = out.charAt(lastPos);
        if (last < 0xAC00 || last > 0xD7A3) return; // not a composed Hangul syllable
        int offsetInSyllable = (last - HANGUL_BASE) % JONGSEONG_COUNT;
        if (offsetInSyllable != 0) return; // already has a batchim — leave it alone
        out.setCharAt(lastPos, (char) (last + jongseongIndex));
    }
}
