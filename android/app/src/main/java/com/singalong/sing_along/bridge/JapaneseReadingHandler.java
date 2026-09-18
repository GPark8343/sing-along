package com.singalong.sing_along.bridge;

import androidx.annotation.NonNull;

import com.atilika.kuromoji.ipadic.Token;
import com.atilika.kuromoji.ipadic.Tokenizer;
import com.singalong.sing_along.text.KanaHangul;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * MethodChannel "sing_along/japanese_reading": kanji/kana -> Korean phonetic reading, done
 * entirely on-device via Kuromoji's morphological analysis + {@link KanaHangul}. Replaces the
 * Claude-based phonetic tier — same job, but with no network round-trip, so it can't be cut off
 * by Android's background process freeze (which was killing the tier for songs looked up while
 * the app was backgrounded; see MediaSessionBridge's poll loop for the matching background story
 * on the position side).
 */
public class JapaneseReadingHandler implements MethodChannel.MethodCallHandler {

    public static final String CHANNEL_NAME = "sing_along/japanese_reading";

    // Loads kuromoji-ipadic's dictionary from the APK's assets on first construction — building
    // it once per process and reusing it avoids paying that cost per line or per song.
    private Tokenizer tokenizer;

    // Words kuromoji-ipadic's dictionary segments into separate morphemes and reads
    // individually, rather than as the single lexicalized (often irregular) word they
    // actually are — 二人 comes back as 二("ni") + 人("nin") instead of the real reading
    // "futari". Checked before tokenization, longest entry first so a word doesn't get
    // shadowed by a shorter one that happens to be a prefix of it.
    private static final Map<String, String> KNOWN_READING_OVERRIDES = new LinkedHashMap<>();

    static {
        KNOWN_READING_OVERRIDES.put("二人", "フタリ");
        KNOWN_READING_OVERRIDES.put("一人", "ヒトリ");
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (!"readingsForLines".equals(call.method)) {
            result.notImplemented();
            return;
        }
        List<String> lines = call.argument("lines");
        if (lines == null) {
            result.success(null);
            return;
        }
        try {
            List<String> readings = new ArrayList<>(lines.size());
            for (String line : lines) {
                readings.add(readingFor(line));
            }
            result.success(readings);
        } catch (Exception e) {
            // Any one malformed line shouldn't take down the whole song's phonetic tier from
            // the caller's perspective — LyricsRepository already treats a null return as
            // "phonetic tier unavailable for this song" and degrades gracefully.
            result.success(null);
        }
    }

    private String readingFor(String line) {
        // One shared buffer for the whole line, not a fresh one per token — ん/っ need to attach
        // a batchim onto whatever was last written, including across a token/chunk boundary
        // (ん very often shows up as its own token, e.g. a casual sentence-final nominalizer).
        StringBuilder out = new StringBuilder();
        int i = 0;
        while (i < line.length()) {
            final int from = i;
            String overrideWord = null;
            for (String word : KNOWN_READING_OVERRIDES.keySet()) {
                if (line.startsWith(word, from)) {
                    overrideWord = word;
                    break;
                }
            }
            if (overrideWord != null) {
                // A manual override is always its own independent word — same as any real
                // content word, it gets a space before it rather than gluing onto whatever
                // came before.
                if (!out.isEmpty()) out.append(' ');
                KanaHangul.appendTransliteration(out, KNOWN_READING_OVERRIDES.get(overrideWord));
                i += overrideWord.length();
                continue;
            }
            // Otherwise, tokenize everything up to the next override match (or line end) as
            // one chunk — kuromoji needs surrounding context to segment/read correctly, so
            // feeding it one token at a time around each override would be worse than feeding
            // it whatever plain stretch of text sits between them.
            int chunkEnd = line.length();
            searchNextOverride:
            for (int j = from + 1; j < line.length(); j++) {
                for (String word : KNOWN_READING_OVERRIDES.keySet()) {
                    if (line.startsWith(word, j)) {
                        chunkEnd = j;
                        break searchNextOverride;
                    }
                }
            }
            appendTokenizedChunk(out, line.substring(from, chunkEnd));
            i = chunkEnd;
        }
        return out.toString();
    }

    private void appendTokenizedChunk(StringBuilder out, String chunk) {
        List<Token> tokens = tokenizer().tokenize(chunk);
        for (Token token : tokens) {
            boolean independent = isIndependentWord(token);
            // A space goes before a new independent word (noun/verb/adjective/...), not before
            // a particle or auxiliary that grammatically attaches to what came before it —
            // otherwise every line reads as one word per space ("요루 니 카케루" instead of the
            // natural "요루니 가케루"), which is technically-readable but not how anyone
            // actually writes a phonetic reading.
            if (independent && !out.isEmpty()) out.append(' ');
            KanaHangul.appendTransliteration(out, readingOf(token));
        }
    }

    // は and へ are spelled with the "ha"/"he" kana but pronounced "wa"/"e" when used as
    // particles (a well-known Japanese orthographic irregularity, e.g. 僕らは = "bokura WA" not
    // "bokura HA") — kuromoji's getReading() returns the literal spelled kana, not the
    // pronunciation, so these two need a manual override rather than trusting the dictionary.
    private String readingOf(Token token) {
        String surface = token.getSurface();
        if ("助詞".equals(token.getPartOfSpeechLevel1())) {
            if ("は".equals(surface)) return "ワ";
            if ("へ".equals(surface)) return "エ";
        }
        String reading = token.getReading();
        // A null/"*" reading means kuromoji couldn't analyze this token (already-Latin text,
        // punctuation, an unrecognized word) — fall back to its literal surface form instead of
        // dropping it, since KanaHangul.appendTransliteration() passes through anything it
        // doesn't recognize unchanged anyway.
        return (reading == null || reading.equals("*")) ? surface : reading;
    }

    private boolean isIndependentWord(Token token) {
        String level1 = token.getPartOfSpeechLevel1();
        if ("助詞".equals(level1) || "助動詞".equals(level1) || "記号".equals(level1) || "接頭詞".equals(level1)) {
            return false;
        }
        String level2 = token.getPartOfSpeechLevel2();
        return level2 == null || !(level2.contains("接尾") || level2.contains("非自立"));
    }

    private Tokenizer tokenizer() {
        if (tokenizer == null) {
            tokenizer = new Tokenizer();
        }
        return tokenizer;
    }
}
