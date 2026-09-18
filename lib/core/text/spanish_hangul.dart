// Spanish -> Hangul phonetic transliteration (독음), entirely rule-based.
//
// Unlike Japanese, Spanish orthography is almost fully phonetic (no kanji,
// few silent letters), so this doesn't need a Kuromoji-style dictionary
// lookup — just letter-to-sound rules plus Spanish syllabification, applied
// directly in Dart. Uses Latin American "seseo"/"yeísmo" pronunciation
// (c/z always as an s-sound, ll/y always as a y-sound) since that's what
// the overwhelming majority of Spanish-language pop/reggaeton uses.

class SpanishHangul {
  static String transliterateLine(String line) {
    final buffer = StringBuffer();
    final wordPattern = RegExp(r'[a-zA-ZÁÉÍÓÚáéíóúÑñÜü]+');
    var last = 0;
    for (final match in wordPattern.allMatches(line)) {
      buffer.write(line.substring(last, match.start));
      buffer.write(_transliterateWord(match.group(0)!));
      last = match.end;
    }
    buffer.write(line.substring(last));
    return buffer.toString();
  }

  static List<String> transliterateLines(List<String> lines) =>
      [for (final line in lines) transliterateLine(line)];

  static String _transliterateWord(String word) {
    final raws = _tokenize(word);
    final elems = _groupElems(raws);
    return _assemble(elems);
  }
}

// ---- Hangul jamo tables + composition ----

const List<String> _leads = ['ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ'];
const List<String> _vowels = ['ㅏ', 'ㅐ', 'ㅑ', 'ㅒ', 'ㅓ', 'ㅔ', 'ㅕ', 'ㅖ', 'ㅗ', 'ㅘ', 'ㅙ', 'ㅚ', 'ㅛ', 'ㅜ', 'ㅝ', 'ㅞ', 'ㅟ', 'ㅠ', 'ㅡ', 'ㅢ', 'ㅣ'];
const List<String?> _finals = [
  null, 'ㄱ', 'ㄲ', 'ㄳ', 'ㄴ', 'ㄵ', 'ㄶ', 'ㄷ', 'ㄹ', 'ㄺ', 'ㄻ', 'ㄼ', 'ㄽ', 'ㄾ', 'ㄿ', 'ㅀ', 'ㅁ', 'ㅂ', 'ㅄ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

String _compose(String? lead, String vowel, String? finalJamo) {
  final leadIdx = lead == null ? 11 : _leads.indexOf(lead);
  final vowelIdx = _vowels.indexOf(vowel);
  final finalIdx = finalJamo == null ? 0 : _finals.indexOf(finalJamo);
  if (leadIdx < 0 || vowelIdx < 0 || finalIdx < 0) return '';
  return String.fromCharCode(0xAC00 + (leadIdx * 21 + vowelIdx) * 28 + finalIdx);
}

String _withCoda(String syllable, String batchimJamo) {
  final finalIdx = _finals.indexOf(batchimJamo);
  return String.fromCharCode(syllable.codeUnitAt(0) + finalIdx);
}

// ---- Consonant sound table ----

class _ConsonantInfo {
  final String? lead; // null = silent onset (ㅇ)
  final bool forcesGlide; // ñ/y/ll/w pull the following vowel into a glide medial
  final String? batchim; // eligible coda jamo, or null if this sound always spills into its own 으-syllable
  const _ConsonantInfo(this.lead, {this.forcesGlide = false, this.batchim});
}

const Map<String, _ConsonantInfo> _consonants = {
  'p': _ConsonantInfo('ㅍ', batchim: 'ㅂ'),
  'b': _ConsonantInfo('ㅂ', batchim: 'ㅂ'),
  't': _ConsonantInfo('ㅌ', batchim: 'ㅅ'),
  'd': _ConsonantInfo('ㄷ', batchim: 'ㅅ'),
  'k': _ConsonantInfo('ㅋ', batchim: 'ㄱ'),
  'g': _ConsonantInfo('ㄱ', batchim: 'ㄱ'),
  'f': _ConsonantInfo('ㅍ', batchim: 'ㅂ'),
  's': _ConsonantInfo('ㅅ'),
  'm': _ConsonantInfo('ㅁ', batchim: 'ㅁ'),
  'n': _ConsonantInfo('ㄴ', batchim: 'ㄴ'),
  'l': _ConsonantInfo('ㄹ', batchim: 'ㄹ'),
  'r': _ConsonantInfo('ㄹ'),
  'ch': _ConsonantInfo('ㅊ'),
  'j_strong': _ConsonantInfo('ㅎ'),
  'ñ': _ConsonantInfo('ㄴ', forcesGlide: true),
  'y': _ConsonantInfo(null, forcesGlide: true),
  'w': _ConsonantInfo(null, forcesGlide: true),
};

const Map<String, String> _plainVowel = {'a': 'ㅏ', 'e': 'ㅔ', 'i': 'ㅣ', 'o': 'ㅗ', 'u': 'ㅜ'};
// weak 'i' + another vowel -> y-glide medial
const Map<String, String> _yGlideTable = {'a': 'ㅑ', 'e': 'ㅖ', 'i': 'ㅣ', 'o': 'ㅛ', 'u': 'ㅠ'};
// weak 'u' + another vowel -> w-glide medial
const Map<String, String> _wGlideTable = {'a': 'ㅘ', 'e': 'ㅞ', 'i': 'ㅟ', 'o': 'ㅝ', 'u': 'ㅜ'};

String _glideJamoForLetter(String weakLetter, String otherLetter) =>
    (weakLetter == 'i' ? _yGlideTable : _wGlideTable)[otherLetter] ?? _plainVowel[otherLetter] ?? 'ㅡ';

// ---- Tokenization: word -> consonant-sound / vowel-letter stream ----

abstract class _Raw {}

class _RawCons extends _Raw {
  final String key;
  _RawCons(this.key);
}

class _RawVowel extends _Raw {
  final String letter;
  _RawVowel(this.letter);
}

const Map<String, String> _accentStrip = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u',
};

bool _isVowelLetter(String c) => c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u';

List<_Raw> _tokenize(String word) {
  final lower = word.toLowerCase();
  // Normalize accented vowels to their base letter (stress doesn't change
  // pronunciation quality for our purposes) while keeping ü/ñ distinct.
  final chars = [for (var i = 0; i < lower.length; i++) _accentStrip[lower[i]] ?? lower[i]];

  final raws = <_Raw>[];
  var i = 0;
  while (i < chars.length) {
    final c = chars[i];
    final c2 = i + 1 < chars.length ? chars[i] + chars[i + 1] : '';

    if (c2 == 'ch') {
      raws.add(_RawCons('ch'));
      i += 2;
      continue;
    }
    if (c2 == 'll') {
      raws.add(_RawCons('y'));
      i += 2;
      continue;
    }
    if (c2 == 'rr') {
      raws.add(_RawCons('r'));
      i += 2;
      continue;
    }
    if (c == 'q') {
      // Spanish 'q' is always followed by a (usually silent) 'u'.
      if (i + 1 < chars.length && chars[i + 1] == 'u') {
        raws.add(_RawCons('k'));
        i += 2;
        continue;
      }
      raws.add(_RawCons('k'));
      i += 1;
      continue;
    }
    if (c == 'g') {
      final next = i + 1 < chars.length ? chars[i + 1] : '';
      final nextNext = i + 2 < chars.length ? chars[i + 2] : '';
      if (next == 'ü') {
        raws.add(_RawCons('g'));
        i += 1; // ü itself is processed next iteration as vowel 'u'
        continue;
      }
      if (next == 'u' && (nextNext == 'e' || nextNext == 'i')) {
        raws.add(_RawCons('g'));
        i += 2; // silent u
        continue;
      }
      if (next == 'e' || next == 'i') {
        raws.add(_RawCons('j_strong'));
        i += 1;
        continue;
      }
      raws.add(_RawCons('g'));
      i += 1;
      continue;
    }
    if (c == 'ü') {
      raws.add(_RawVowel('u'));
      i += 1;
      continue;
    }
    if (c == 'ñ') {
      raws.add(_RawCons('ñ'));
      i += 1;
      continue;
    }
    if (c == 'h') {
      i += 1; // silent
      continue;
    }
    if (c == 'c') {
      final next = i + 1 < chars.length ? chars[i + 1] : '';
      if (next == 'e' || next == 'i') {
        raws.add(_RawCons('s'));
      } else {
        raws.add(_RawCons('k'));
      }
      i += 1;
      continue;
    }
    if (c == 'z') {
      raws.add(_RawCons('s'));
      i += 1;
      continue;
    }
    if (c == 'j') {
      raws.add(_RawCons('j_strong'));
      i += 1;
      continue;
    }
    if (c == 'x') {
      final prevIsVowel = raws.isNotEmpty && raws.last is _RawVowel;
      final next = i + 1 < chars.length ? chars[i + 1] : '';
      if (prevIsVowel && _isVowelLetter(next)) {
        // Intervocalic x ("taxi") is a /ks/ cluster: coda ㄱ + onset ㅅ.
        raws.add(_RawCons('k'));
        raws.add(_RawCons('s'));
      } else {
        raws.add(_RawCons('s'));
      }
      i += 1;
      continue;
    }
    if (c == 'y') {
      final next = i + 1 < chars.length ? chars[i + 1] : '';
      if (_isVowelLetter(next)) {
        raws.add(_RawCons('y'));
      } else {
        raws.add(_RawVowel('i')); // word-final/standalone y sounds like "i"
      }
      i += 1;
      continue;
    }
    if (c == 'w') {
      raws.add(_RawCons('w'));
      i += 1;
      continue;
    }
    if (c == 'b' || c == 'v') {
      raws.add(_RawCons('b'));
      i += 1;
      continue;
    }
    if (_isVowelLetter(c)) {
      raws.add(_RawVowel(c));
      i += 1;
      continue;
    }
    if (_consonants.containsKey(c)) {
      raws.add(_RawCons(c));
      i += 1;
      continue;
    }
    i += 1; // unrecognized character, skip
  }
  return raws;
}

// ---- Vowel-run grouping: Spanish diphthong/hiatus rules ----

class _RawNucleus {
  final String vowelLetter;
  final String vowelJamo;
  final bool canGlideShift; // true only for a genuinely single, unmerged vowel
  _RawNucleus(this.vowelLetter, this.vowelJamo, this.canGlideShift);
}

bool _isWeak(String v) => v == 'i' || v == 'u';

List<_RawNucleus> _groupVowelRun(List<String> vs) {
  final out = <_RawNucleus>[];
  var i = 0;
  while (i < vs.length) {
    if (i + 1 < vs.length) {
      final a = vs[i];
      final b = vs[i + 1];
      if (_isWeak(a) && !_isWeak(b)) {
        // weak+strong: one syllable, glide onto the strong vowel.
        out.add(_RawNucleus(a, _glideJamoForLetter(a, b), false));
        i += 2;
        continue;
      }
      if (!_isWeak(a) && _isWeak(b)) {
        // strong+weak: two syllables (strong vowel, then a trailing 이/우).
        out.add(_RawNucleus(a, _plainVowel[a]!, true));
        out.add(_RawNucleus(b, b == 'i' ? 'ㅣ' : 'ㅜ', false));
        i += 2;
        continue;
      }
      if (_isWeak(a) && _isWeak(b)) {
        out.add(_RawNucleus(a, _glideJamoForLetter(a, b), false));
        i += 2;
        continue;
      }
      // both strong -> hiatus, don't merge; fall through to single-vowel case.
    }
    out.add(_RawNucleus(vs[i], _plainVowel[vs[i]]!, true));
    i += 1;
  }
  return out;
}

List<Object> _groupElems(List<_Raw> raws) {
  final elems = <Object>[];
  var i = 0;
  while (i < raws.length) {
    final r = raws[i];
    if (r is _RawCons) {
      elems.add(r);
      i += 1;
      continue;
    }
    final run = <String>[];
    var j = i;
    while (j < raws.length && raws[j] is _RawVowel) {
      run.add((raws[j] as _RawVowel).letter);
      j += 1;
    }
    elems.addAll(_groupVowelRun(run));
    i = j;
  }
  return elems;
}

// ---- Assembly: consonants attach to the following nucleus (Spanish is
// onset-maximizing); word-final or clustered consonants spill into their
// own 으-syllable unless they're one of the handful of Hangul-batchim-
// eligible sounds. ----

String _assemble(List<Object> elems) {
  final syllables = <String>[];
  final pending = <String>[];

  void flush(_RawNucleus nucleus) {
    String? onsetLead;
    var vowelJamo = nucleus.vowelJamo;
    if (pending.isEmpty) {
      onsetLead = null;
    } else if (pending.length == 1) {
      final info = _consonants[pending[0]]!;
      onsetLead = info.lead;
      if (info.forcesGlide && nucleus.canGlideShift) {
        vowelJamo = _glideJamoForLetter(pending[0] == 'w' ? 'u' : 'i', nucleus.vowelLetter);
      }
    } else {
      final first = pending.first;
      final middle = pending.sublist(1, pending.length - 1);
      final lastKey = pending.last;
      final firstInfo = _consonants[first]!;
      // Obstruent+liquid onset clusters (pl, bl, cl, gl, fl, pr, br, cr, gr,
      // fr, tr, dr) stay together as a single Spanish syllable; Hangul has
      // no 2-consonant onset, so the liquid is doubled — once as the
      // filler syllable's coda, once as the real onset of the vowel that
      // follows (matches established convention, e.g. English "flag" -> 플래그).
      final isLiquidCluster = middle.isEmpty && (lastKey == 'l' || lastKey == 'r');
      if (isLiquidCluster) {
        syllables.add(_compose(firstInfo.lead, 'ㅡ', 'ㄹ'));
      } else if (firstInfo.batchim != null && syllables.isNotEmpty) {
        var coda = firstInfo.batchim!;
        if (first == 'n') {
          // Spanish 'n' assimilates in place to a following consonant:
          // velar (g/k/c/qu) -> ㅇ, labial (p/b/f/m) -> ㅁ, else stays ㄴ.
          final nextLead = _consonants[middle.isNotEmpty ? middle.first : lastKey]!.lead;
          if (nextLead == 'ㄱ' || nextLead == 'ㅋ') {
            coda = 'ㅇ';
          } else if (nextLead == 'ㅂ' || nextLead == 'ㅍ' || nextLead == 'ㅁ') {
            coda = 'ㅁ';
          }
        }
        syllables[syllables.length - 1] = _withCoda(syllables.last, coda);
      } else {
        syllables.add(_compose(firstInfo.lead, 'ㅡ', null));
      }
      for (final midKey in middle) {
        final midInfo = _consonants[midKey]!;
        syllables.add(_compose(midInfo.lead, 'ㅡ', null));
      }
      final lastInfo = _consonants[lastKey]!;
      onsetLead = lastInfo.lead;
      if (lastInfo.forcesGlide && nucleus.canGlideShift) {
        vowelJamo = _glideJamoForLetter(lastKey == 'w' ? 'u' : 'i', nucleus.vowelLetter);
      }
    }
    pending.clear();
    syllables.add(_compose(onsetLead, vowelJamo, null));
  }

  for (final e in elems) {
    if (e is _RawCons) {
      pending.add(e.key);
      continue;
    }
    flush(e as _RawNucleus);
  }

  if (pending.isNotEmpty) {
    if (pending.length == 1) {
      final info = _consonants[pending[0]]!;
      if (info.batchim != null && syllables.isNotEmpty) {
        syllables[syllables.length - 1] = _withCoda(syllables.last, info.batchim!);
      } else {
        syllables.add(_compose(info.lead, 'ㅡ', null));
      }
    } else {
      for (final key in pending) {
        final info = _consonants[key]!;
        syllables.add(_compose(info.lead, 'ㅡ', null));
      }
    }
  }

  return syllables.join();
}
