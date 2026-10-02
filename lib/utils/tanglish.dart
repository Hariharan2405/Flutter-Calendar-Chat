/// Language routing for text-to-speech over English / Tamil / Tanglish chat.
///
/// The problem this solves: a platform TTS engine given the Latin string
/// "epdi iruka" reads it with English phonetics and the result is unusable.
/// Tamil typed in Latin script ("Tanglish") therefore has to be converted to
/// Tamil script *before* it reaches the engine, and only then spoken with a
/// Tamil voice. Text already in Tamil script goes straight to the Tamil voice,
/// and genuine English goes to the English voice.
///
/// So the pipeline is: split into clauses → classify each clause as Tamil or
/// English → transliterate the Tanglish ones → emit one [SpeechRun] per
/// language stretch.
library;

/// A stretch of text to be spoken with one voice/locale.
class SpeechRun {
  final String text;

  /// `true` when this run must be spoken by the Tamil voice.
  final bool isTamil;

  /// The text as the user typed it, before any transliteration. When no Tamil
  /// voice exists the run has to go to the English voice, and that voice can
  /// approximate Latin-letter Tanglish but cannot pronounce Tamil script at
  /// all — handing it [text] produced silence.
  final String original;

  const SpeechRun(this.text, {required this.isTamil, String? original})
      : original = original ?? text;

  @override
  String toString() => '${isTamil ? "ta" : "en"}: $text';
}

// ── Script detection ──────────────────────────────────────────────────────────

/// Tamil block is U+0B80–U+0BFF.
bool _isTamilCodeUnit(int c) => c >= 0x0B80 && c <= 0x0BFF;

bool hasTamilScript(String s) {
  for (final c in s.codeUnits) {
    if (_isTamilCodeUnit(c)) return true;
  }
  return false;
}

// ── Lexicon of common Tanglish words ─────────────────────────────────────────
//
// Rule-based transliteration alone mangles everyday words, because romanised
// Tamil is wildly inconsistent (ழ/ள/ல all get typed "l", ட/த both get "d").
// Casual chat is dominated by a small vocabulary, so spelling those out by hand
// buys most of the accuracy. Anything not listed falls through to the rules.
const Map<String, String> _lexicon = {
  // pronouns / people
  'naan': 'நான்', 'naa': 'நா', 'nan': 'நான்',
  'nee': 'நீ', 'ni': 'நீ', 'neenga': 'நீங்க', 'ninga': 'நீங்க',
  'neengal': 'நீங்கள்',
  'avan': 'அவன்', 'aval': 'அவள்', 'avar': 'அவர்', 'avanga': 'அவங்க',
  'ivan': 'இவன்', 'ival': 'இவள்', 'ivanga': 'இவங்க',
  'naama': 'நாம', 'naam': 'நாம்', 'naanga': 'நாங்க', 'ellam': 'எல்லாம்',
  'ellarum': 'எல்லாரும்', 'yaaru': 'யாரு', 'yar': 'யார்', 'yaar': 'யார்',
  'amma': 'அம்மா', 'appa': 'அப்பா', 'anna': 'அண்ணா', 'akka': 'அக்கா',
  'thambi': 'தம்பி', 'thangachi': 'தங்கச்சி', 'machan': 'மச்சான்',
  'nanba': 'நண்பா', 'nanban': 'நண்பன்', 'da': 'டா', 'di': 'டி',
  'pa': 'பா', 'ma': 'மா', 'thala': 'தல',

  // questions
  'enna': 'என்ன', 'ena': 'என்ன', 'yenna': 'என்ன',
  'epdi': 'எப்படி', 'eppadi': 'எப்படி', 'epadi': 'எப்படி',
  'eppo': 'எப்போ', 'eppothu': 'எப்பொழுது', 'yeppo': 'எப்போ',
  'enga': 'எங்க', 'engae': 'எங்கே', 'enge': 'எங்கே', 'yenga': 'எங்க',
  'yen': 'ஏன்', 'en': 'ஏன்', 'edhu': 'எது', 'ethu': 'எது',
  'evlo': 'எவ்வளோ', 'evvalavu': 'எவ்வளவு', 'ethana': 'எத்தன',

  // verbs — the high-frequency conjugations
  'iruku': 'இருக்கு', 'irukku': 'இருக்கு', 'iruka': 'இருக்கா',
  'irukka': 'இருக்கா', 'irukkanga': 'இருக்காங்க', 'iruken': 'இருக்கேன்',
  'irukken': 'இருக்கேன்', 'irundhu': 'இருந்து', 'irundha': 'இருந்தா',
  'illa': 'இல்ல', 'illai': 'இல்லை', 'ille': 'இல்ல',
  'varen': 'வரேன்', 'varuven': 'வருவேன்', 'vandhu': 'வந்து',
  'vandha': 'வந்தா', 'vanga': 'வாங்க', 'vaa': 'வா', 'varutha': 'வருதா',
  'poren': 'போறேன்', 'ponen': 'போனேன்', 'poga': 'போக', 'po': 'போ',
  'pogalam': 'போகலாம்', 'polam': 'போலாம்', 'poitu': 'போயிட்டு',
  'sollu': 'சொல்லு', 'solla': 'சொல்ல', 'sonna': 'சொன்னா',
  'sonnen': 'சொன்னேன்', 'solren': 'சொல்றேன்', 'sollunga': 'சொல்லுங்க',
  'panren': 'பண்றேன்', 'panna': 'பண்ண', 'pannu': 'பண்ணு',
  'pannunga': 'பண்ணுங்க', 'panniten': 'பண்ணிட்டேன்',
  'paaru': 'பாரு', 'paru': 'பாரு', 'parunga': 'பாருங்க',
  'theriyum': 'தெரியும்', 'theriyala': 'தெரியல', 'theriyuma': 'தெரியுமா',
  'puriyala': 'புரியல', 'puriyudha': 'புரியுதா',
  'venum': 'வேணும்', 'vendum': 'வேண்டும்', 'venam': 'வேணாம்',
  'mudiyala': 'முடியல', 'mudiyum': 'முடியும்', 'mudinjadhu': 'முடிந்தது',
  'saptiya': 'சாப்ட்டியா', 'saapta': 'சாப்ட்டா', 'saapdu': 'சாப்டு',
  'thoongu': 'தூங்கு', 'thoongiten': 'தூங்கிட்டேன்',
  'kekuthu': 'கேக்குது', 'kelu': 'கேளு', 'kettu': 'கேட்டு',
  'kudu': 'குடு', 'kudunga': 'குடுங்க', 'kuduthen': 'குடுத்தேன்',
  'edu': 'எடு', 'eduthen': 'எடுத்தேன்', 'vittu': 'விட்டு',
  'mudi': 'முடி', 'aayiduchu': 'ஆயிடுச்சு', 'aachu': 'ஆச்சு',
  'aaguma': 'ஆகுமா', 'aagum': 'ஆகும்',

  // affirmation / negation / fillers
  'aama': 'ஆமா', 'aamam': 'ஆமாம்', 'ama': 'ஆமா',
  'seri': 'சரி', 'sari': 'சரி', 'shari': 'சரி',
  'romba': 'ரொம்ப', 'rombha': 'ரொம்ப', 'konjam': 'கொஞ்சம்',
  'nalla': 'நல்ல', 'nallam': 'நல்லா', 'nallairuku': 'நல்லாஇருக்கு',
  'semma': 'செம்ம',
  'vera': 'வேற', 'veru': 'வேறு',
  'apdi': 'அப்படி', 'appadi': 'அப்படி', 'ipdi': 'இப்படி',
  'ippadi': 'இப்படி', 'adhu': 'அது', 'athu': 'அது', 'idhu': 'இது',
  'ithu': 'இது', 'ange': 'அங்க', 'inge': 'இங்க', 'anga': 'அங்க',
  'inga': 'இங்க', 'appo': 'அப்போ', 'ippo': 'இப்போ', 'ipo': 'இப்போ',
  'piragu': 'பிறகு', 'apram': 'அப்புறம்', 'appuram': 'அப்புறம்',
  'munnadi': 'முன்னாடி', 'pinnadi': 'பின்னாடி',
  'mattum': 'மட்டும்', 'kuda': 'கூட', 'kooda': 'கூட',
  'ku': 'கு', 'la': 'ல', 'nu': 'னு', 'nnu': 'ன்னு',
  'thaan': 'தான்', 'than': 'தான்', 'dhan': 'தான்',
  'aana': 'ஆனா', 'aanaa': 'ஆனா', 'aprm': 'அப்புறம்',

  // time
  'indha': 'இந்த', 'inda': 'இந்த', 'antha': 'அந்த', 'anda': 'அந்த',
  'innaiku': 'இன்னைக்கு', 'innaikku': 'இன்னைக்கு', 'inaiku': 'இன்னைக்கு',
  'naalaiku': 'நாளைக்கு', 'nalaiku': 'நாளைக்கு', 'nethu': 'நேத்து',
  'neththu': 'நேத்து', 'raatri': 'ராத்திரி', 'ratri': 'ராத்திரி',
  'kaalai': 'காலை', 'kaalaila': 'காலைல', 'saayangalam': 'சாயங்காலம்',
  'neram': 'நேரம்', 'naal': 'நாள்', 'maasam': 'மாசம்',
  'varusham': 'வருஷம்', 'vaaram': 'வாரம்',

  // greetings / courtesy
  'vanakkam': 'வணக்கம்', 'nandri': 'நன்றி',

  // objects / misc common nouns
  'veedu': 'வீடு', 'veetu': 'வீட்டு', 'veetuku': 'வீட்டுக்கு',
  'saapadu': 'சாப்பாடு', 'thanni': 'தண்ணி', 'kaasu': 'காசு',
  'panam': 'பணம்', 'velai': 'வேல', 'vela': 'வேல', 'padam': 'படம்',
  'ooru': 'ஊரு', 'oor': 'ஊர்', 'chennai': 'சென்னை',
  'thalaivali': 'தலவலி', 'usuru': 'உசுரு',

  // datives and common verb forms
  'enakku': 'எனக்கு', 'enaku': 'எனக்கு', 'unakku': 'உனக்கு',
  'unaku': 'உனக்கு', 'namakku': 'நமக்கு', 'avanukku': 'அவனுக்கு',
  'avalukku': 'அவளுக்கு', 'ungalukku': 'உங்களுக்கு',
  'vendam': 'வேண்டாம்', 'vendaam': 'வேண்டாம்', 'venaam': 'வேணாம்',
  'venuma': 'வேணுமா', 'pannalam': 'பண்ணலாம்', 'panlam': 'பண்லாம்',
  'panra': 'பண்ற', 'panringa': 'பண்றீங்க', 'pannala': 'பண்ணல',
  'mudiyathu': 'முடியாது', 'theriyathu': 'தெரியாது', 'puriyuthu': 'புரியுது',
  'pesuren': 'பேசுறேன்', 'pesalama': 'பேசலாமா', 'pesu': 'பேசு',
  'solra': 'சொல்ற', 'sollala': 'சொல்லல', 'varala': 'வரல',
  'varuviya': 'வருவியா', 'poitiya': 'போயிட்டியா', 'irukkiya': 'இருக்கியா',
  'irukeengala': 'இருக்கீங்களா', 'aagatum': 'ஆகட்டும்',
  'ennachu': 'என்னாச்சு', 'illana': 'இல்லனா', 'illanna': 'இல்லன்னா',
  'apdiya': 'அப்படியா', 'appadiya': 'அப்படியா',
  // particles and fillers
  'kitta': 'கிட்ட', 'pola': 'போல', 'mathiri': 'மாதிரி', 'maari': 'மாறி',
  'kandippa': 'கண்டிப்பா', 'seekiram': 'சீக்கிரம்', 'sikiram': 'சீக்கிரம்',
  'chumma': 'சும்மா', 'summa': 'சும்மா', 'aiyo': 'ஐயோ', 'ayyo': 'அய்யோ',
  'paavam': 'பாவம்', 'vaada': 'வாடா', 'vaadi': 'வாடி', 'poda': 'போடா',
  'podi': 'போடி', 'kadavule': 'கடவுளே', 'neeyum': 'நீயும்',
  'naanum': 'நானும்', 'oru': 'ஒரு', 'rendu': 'ரெண்டு', 'moonu': 'மூணு',
  'adutha': 'அடுத்த', 'veliya': 'வெளிய', 'ulla': 'உள்ள', 'mela': 'மேல',
  'thookam': 'தூக்கம்', 'nallaa': 'நல்லா',
};

/// English words used inside Tanglish, spelled the way a Tamil speaker says
/// them. Kept apart from [_lexicon] because they are evidence of nothing when
/// classifying — an English message is full of them too.
const Map<String, String> _loanwords = {
  'ok': 'ஓகே',
  'okay': 'ஓகே',
  'sorry': 'சாரி',
  'thanks': 'தேங்க்ஸ்',
  'please': 'ப்ளீஸ்',
  'hi': 'ஹாய்',
  'hello': 'ஹலோ',
  'bye': 'பை',
  'good': 'குட்',
  'morning': 'மார்னிங்',
  'night': 'நைட்',
  'super': 'சூப்பர்',
  'mass': 'மாஸ்',
  'level': 'லெவல்',
  'wait': 'வெயிட்',
  'sight': 'சைட்',
  'office': 'ஆபீஸ்',
  'phone': 'போன்',
  'call': 'கால்',
  'message': 'மெசேஜ்',
  'msg': 'மெசேஜ்',
  'photo': 'போட்டோ',
  'car': 'கார்',
  'bus': 'பஸ்',
  'bike': 'பைக்',
  'train': 'ட்ரெயின்',
  'but': 'பட்',
  'so': 'சோ',
  'then': 'தென்',
  'and': 'அண்ட்',
  'time': 'டைம்',
  'late': 'லேட்',
  'leave': 'லீவ்',
  'busy': 'பிஸி',
  'evening': 'ஈவினிங்',
  'boss': 'பாஸ்',
  'free': 'ஃப்ரீ',
  'home': 'ஹோம்',
  'work': 'வொர்க்',
  'done': 'டன்',
  'fine': 'ஃபைன்',
  'yes': 'எஸ்',
  'no': 'நோ',
  'sure': 'ஷ்யூர்',
  'tomorrow': 'டுமாரோ',
  'today': 'டுடே',
  'meeting': 'மீட்டிங்',
  'class': 'கிளாஸ்',
  'exam': 'எக்ஸாம்',
  'movie': 'மூவி',
  'shop': 'ஷாப்',
  'food': 'ஃபுட்',
  'tea': 'டீ',
  'coffee': 'காஃபி',
  'money': 'மணி',
  'friend': 'ஃப்ரெண்ட்',
  'family': 'ஃபேமிலி',
  'plan': 'பிளான்',
  'idea': 'ஐடியா',
  'problem': 'ப்ராப்ளம்',
  'tension': 'டென்ஷன்',
  'happy': 'ஹேப்பி',
  'enjoy': 'என்ஜாய்',
  'nice': 'நைஸ்',
  'cute': 'க்யூட்',
  'correct': 'கரெக்ட்',
  'wrong': 'ராங்',
  'right': 'ரைட்',
  'ready': 'ரெடி',
  'start': 'ஸ்டார்ட்',
  'finish': 'ஃபினிஷ்',
  'reach': 'ரீச்',
  'ticket': 'டிக்கெட்',
  'number': 'நம்பர்',
  'address': 'அட்ரஸ்',
  'location': 'லொகேஷன்',
  'video': 'வீடியோ',
  'status': 'ஸ்டேட்டஸ்',
  'chat': 'சாட்',
  'online': 'ஆன்லைன்',
  'charge': 'சார்ஜ்',
  'mobile': 'மொபைல்',
  'net': 'நெட்',
  'hospital': 'ஹாஸ்பிட்டல்',
  'doctor': 'டாக்டர்',
  'school': 'ஸ்கூல்',
  'college': 'காலேஜ்',
  'bro': 'ப்ரோ',
  'mummy': 'மம்மி',
  'daddy': 'டாடி',
};

/// Words whose presence strongly implies romanised Tamil even though they are
/// short, plus suffix patterns Tamil uses and English does not.
const List<String> _tamilSuffixMarkers = [
  'kku',
  'ngal',
  'anga',
  'inga',
  'unga',
  'irukku',
  'aaga',
  'aana',
  'nnu',
  'laam',
  'udhu',
  'uthu',
  'achu',
  'ichu',
  'aren',
  'oren',
  'iten',
  'itten',
  'aachu',
  'thaan',
];

/// Common English words. They outweigh accidental lexicon hits on words like
/// "da" or "ma", and let a message made only of known English words skip the
/// Gemini rewrite entirely — faster, and one fewer request.
const Set<String> _englishCommon = {
  'me',
  'my',
  'we',
  'us',
  'our',
  'he',
  'him',
  'his',
  'she',
  'her',
  'it',
  'its',
  'is',
  'am',
  'be',
  'do',
  'does',
  'go',
  'goes',
  'to',
  'of',
  'in',
  'on',
  'at',
  'by',
  'up',
  'if',
  'or',
  'as',
  'an',
  'so',
  'no',
  'not',
  'see',
  'say',
  'said',
  'tell',
  'told',
  'ask',
  'call',
  'check',
  'look',
  'give',
  'keep',
  'think',
  'feel',
  'try',
  'use',
  'find',
  'found',
  'leave',
  'put',
  'mean',
  'meet',
  'talk',
  'wait',
  'stay',
  'sleep',
  'eat',
  'read',
  'write',
  'buy',
  'pay',
  'open',
  'close',
  'start',
  'stop',
  'help',
  'bring',
  'reach',
  'report',
  'email',
  'mail',
  'file',
  'link',
  'photo',
  'video',
  'phone',
  'again',
  'always',
  'never',
  'maybe',
  'really',
  'sure',
  'okay',
  'ok',
  'sorry',
  'thanks',
  'please',
  'hello',
  'hi',
  'bye',
  'good',
  'great',
  'nice',
  'fine',
  'bad',
  'late',
  'early',
  'soon',
  'later',
  'tonight',
  'yesterday',
  'week',
  'month',
  'year',
  'morning',
  'evening',
  'night',
  'pm',
  'one',
  'two',
  'three',
  'first',
  'last',
  'next',
  'other',
  'same',
  'new',
  'old',
  'big',
  'small',
  'lot',
  'many',
  'few',
  'every',
  'each',
  'something',
  'nothing',
  'anything',
  'everything',
  'someone',
  'everyone',
  'place',
  'house',
  'office',
  'school',
  'money',
  'food',
  'car',
  'bus',
  'sir',
  'madam',
  'friend',
  'family',
  'mom',
  'dad',
  'baby',
  'happy',
  'birthday',
  'congrats',
  'congratulations',
  'wish',
  'hope',
  'miss',
  'which',
  'whose',
  'while',
  'than',
  'too',
  'only',
  'even',
  'well',
  'back',
  'over',
  'into',
  'down',
  'off',
  'right',
  'left',
  'around',
  'without',
  'through',
  'ready',
  'free',
  'busy',
  'done',
  'coming',
  'leaving',
  'having',
  'working',
  'waiting',
  'reached',
  'calling',
  'message',
  'reply',
  'the',
  'and',
  'you',
  'are',
  'for',
  'but',
  'can',
  'will',
  'have',
  'has',
  'was',
  'were',
  'this',
  'that',
  'with',
  'from',
  'they',
  'them',
  'what',
  'when',
  'where',
  'how',
  'why',
  'who',
  'your',
  'been',
  'about',
  'would',
  'could',
  'should',
  'there',
  'their',
  'here',
  'just',
  'like',
  'know',
  'need',
  'want',
  'come',
  'going',
  'get',
  'got',
  'let',
  'make',
  'made',
  'take',
  'time',
  'day',
  'today',
  'tomorrow',
  'now',
  'then',
  'yes',
  'yeah',
  'thank',
  'welcome',
  'love',
  'work',
  'home',
  'meeting',
  'send',
  'sent',
  'doing',
  'did',
  'much',
  'very',
  'more',
  'some',
  'any',
  'all',
  'out',
  'also',
  'because',
  'after',
  'before',
  'still',
};

// ── Rule-based transliteration ───────────────────────────────────────────────
//
// Greedy longest-match over romanisation clusters. Ordering inside each table
// matters: longer keys must be tried first, which `_sortedKeys` guarantees.

/// Consonant → Tamil consonant letter (which carries an inherent "a").
const Map<String, String> _consonants = {
  'ksh': 'க்ஷ',
  'zh': 'ழ',
  'ng': 'ங',
  'nj': 'ஞ',
  'gn': 'ஞ',
  'ch': 'ச',
  'sh': 'ஷ',
  'th': 'த',
  'dh': 'த',
  'tr': 'ட்ர',
  'k': 'க',
  'g': 'க',
  'q': 'க',
  'c': 'க',
  's': 'ச',
  'j': 'ஜ',
  't': 'ட',
  'd': 'ட',
  'n': 'ன',
  'p': 'ப',
  'b': 'ப',
  'f': 'ப',
  'm': 'ம',
  'y': 'ய',
  'r': 'ர',
  'l': 'ல',
  'v': 'வ',
  'w': 'வ',
  'h': 'ஹ',
  'x': 'க்ஸ',
};

/// Vowel → (independent letter, dependent sign).
const Map<String, List<String>> _vowels = {
  'aa': ['ஆ', 'ா'],
  'ai': ['ஐ', 'ை'],
  'au': ['ஔ', 'ௌ'],
  'ee': ['ஈ', 'ீ'],
  'ii': ['ஈ', 'ீ'],
  'ea': ['ஈ', 'ீ'],
  'oo': ['ஊ', 'ூ'],
  'uu': ['ஊ', 'ூ'],
  'ou': ['ஔ', 'ௌ'],
  'ae': ['ஏ', 'ே'],
  'oa': ['ஓ', 'ோ'],
  'a': ['அ', ''],
  'i': ['இ', 'ி'],
  'u': ['உ', 'ு'],
  'e': ['எ', 'ெ'],
  'o': ['ஒ', 'ொ'],
};

const String _pulli = '்'; // virama — strips the inherent vowel

List<String>? _consonantKeys;
List<String>? _vowelKeys;

List<String> _sortedKeys(Map<String, dynamic> m) =>
    m.keys.toList()..sort((a, b) => b.length.compareTo(a.length));

/// Transliterates one romanised Tamil word into Tamil script.
String _translitWord(String w) {
  _consonantKeys ??= _sortedKeys(_consonants);
  _vowelKeys ??= _sortedKeys(_vowels);

  final out = StringBuffer();
  int i = 0;
  bool atStart = true;

  while (i < w.length) {
    // A doubled consonant ("pp", "kk", "tt") is gemination: emit the bare
    // consonant with a pulli, then let the next pass handle the second one.
    final two = i + 1 < w.length ? w.substring(i, i + 2) : '';
    if (two.length == 2 &&
        two[0] == two[1] &&
        _consonants.containsKey(two[0]) &&
        !_vowels.containsKey(two[0])) {
      out.write(_consonants[two[0]]! + _pulli);
      i += 1;
      atStart = false;
      continue;
    }

    String? cons;
    for (final k in _consonantKeys!) {
      if (w.startsWith(k, i)) {
        cons = k;
        break;
      }
    }

    if (cons != null) {
      // Word-initial "n" is dental ந in Tamil, elsewhere alveolar ன.
      var letter = _consonants[cons]!;
      if (cons == 'n' && atStart) letter = 'ந';
      i += cons.length;

      String? vow;
      for (final k in _vowelKeys!) {
        if (w.startsWith(k, i)) {
          vow = k;
          break;
        }
      }
      if (vow == null) {
        out.write(letter + _pulli); // bare consonant
      } else {
        out.write(letter + _vowels[vow]![1]);
        i += vow.length;
      }
      atStart = false;
      continue;
    }

    String? vow;
    for (final k in _vowelKeys!) {
      if (w.startsWith(k, i)) {
        vow = k;
        break;
      }
    }
    if (vow != null) {
      out.write(_vowels[vow]![0]); // independent vowel form
      i += vow.length;
      atStart = false;
      continue;
    }

    out.write(w[i]); // digit or stray symbol — pass through
    i += 1;
    atStart = false;
  }
  return out.toString();
}

/// Converts a romanised-Tamil clause to Tamil script, word by word, preferring
/// the hand-written lexicon over the rules.
String transliterateTanglish(String clause) {
  // Tokenise into words *and* whitespace runs. `String.split` with a capturing
  // group does not keep the separator in Dart (unlike JS), which silently
  // glued every word together.
  return RegExp(r'\s+|\S+').allMatches(clause).map((tokMatch) {
    final tok = tokMatch[0]!;
    if (tok.trim().isEmpty) return tok;
    // Keep leading/trailing punctuation so intonation survives.
    final m = RegExp(r'^([^\w]*)(.*?)([^\w]*)$').firstMatch(tok);
    final lead = m?.group(1) ?? '';
    final core = m?.group(2) ?? tok;
    final tail = m?.group(3) ?? '';
    if (core.isEmpty) return tok;
    if (hasTamilScript(core)) return tok;
    final lower = core.toLowerCase();
    final hit = _lexicon[lower] ?? _loanwords[lower];
    if (hit != null) return '$lead$hit$tail';
    // Pure numbers stay as numbers — the Tamil voice reads them in Tamil.
    if (RegExp(r'^\d+$').hasMatch(core)) return tok;
    return '$lead${_translitWord(lower)}$tail';
  }).join();
}

// ── Classification ───────────────────────────────────────────────────────────

/// Scores a Latin-script clause and decides whether it is romanised Tamil.
bool looksTanglish(String clause) {
  final words = clause
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.length > 1)
      .toList();
  if (words.isEmpty) return false;

  int tamil = 0;
  int english = 0;
  for (final w in words) {
    if (_lexicon.containsKey(w)) {
      tamil += 1;
      continue;
    }
    if (_englishCommon.contains(w)) {
      english += 1;
      continue;
    }
    // Loanwords are only there for pronunciation; they prove nothing.
    if (_loanwords.containsKey(w)) continue;
    if (_tamilSuffixMarkers.any((s) => w.endsWith(s)) || w.contains('zh')) {
      tamil += 2;
    }
  }
  if (tamil == 0) return false;
  // Tamil evidence has to at least rival the English evidence; a single stray
  // hit in an otherwise English sentence stays English.
  return tamil * 2 >= english;
}

// ── Message-level decisions ──────────────────────────────────────────────────

/// Which voice a whole message should be read in.
enum MessageLanguage {
  /// Tamil script, or Tanglish: the entire message is read in Tamil.
  tamil,

  /// Made only of known English words: read in English, no rewrite needed.
  english,

  /// Can't tell locally; the Gemini rewrite decides.
  unsure,
}

/// Decides the voice for the whole message at once.
///
/// Deciding per sentence switched voices mid-message: in
/// "ithu enakku ok. But vendam." the second sentence looked English, so an
/// English voice read the Tamil word "vendam". A message that is Tamil anywhere
/// is now Tamil everywhere.
MessageLanguage classifyMessage(String text) {
  if (hasTamilScript(text) || looksTanglish(text)) return MessageLanguage.tamil;
  final words = text
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.length > 1)
      .toList();
  if (words.isEmpty) return MessageLanguage.english;
  final known = words
      .where((w) => _englishCommon.contains(w) || _loanwords.containsKey(w))
      .length;
  if (known == words.length) return MessageLanguage.english;
  // A longer sentence can carry one unknown word (a name, a typo) and still
  // be clearly English.
  if (words.length >= 4 && known / words.length >= 0.8) {
    return MessageLanguage.english;
  }
  return MessageLanguage.unsure;
}

/// Tidies punctuation that voices otherwise read out loud.
///
/// Any run of dots ("......", ". . .", "…") becomes a single "...", which every
/// engine treats as a pause; longer runs were being spelled out as
/// "dot dot dot dot". Repeated "!!!" and "???" collapse to one mark.
String normalizePunctuation(String text) {
  return text
      .replaceAll(RegExp(r'(?:\.\s*){2,}|…+'), '... ')
      .replaceAllMapped(RegExp(r'([!?])[!?]+'), (m) => m[1]!)
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s+([,.!?])'), r'$1')
      .trim();
}

// Short Tamil vowel → its long form, for drawing a word out.
const Map<String, String> _longerVowelSign = {
  'ி': 'ீ',
  'ு': 'ூ',
  'ெ': 'ே',
  'ொ': 'ோ',
};
const Map<String, String> _longerVowel = {
  'அ': 'ஆ',
  'இ': 'ஈ',
  'உ': 'ஊ',
  'எ': 'ஏ',
  'ஒ': 'ஓ',
};

/// Draws out the last vowel of a Tamil word, the way a speaker trails off
/// before "...": சரி → சரீ, அது → அதூ, டா stays டா (already long).
String stretchTamilWord(String word) {
  if (word.isEmpty) return word;
  final last = word[word.length - 1];
  final head = word.substring(0, word.length - 1);
  final sign = _longerVowelSign[last];
  if (sign != null) return '$head$sign';
  final vowel = _longerVowel[last];
  if (vowel != null) return '$head$vowel';
  final c = last.codeUnitAt(0);
  // A bare consonant carries a short "a": add the long-a sign.
  if (c >= 0x0B95 && c <= 0x0BB9) return '${word}ா';
  return word;
}

/// Stretches the word before every "..." — the offline voice has no way to
/// trail off on its own, and an ellipsis marks exactly where a speaker would.
String stretchBeforeEllipsis(String text) {
  return text.replaceAllMapped(
    RegExp(r'([^\s.]+)\.\.\.'),
    (m) => '${stretchTamilWord(m[1]!)}...',
  );
}

/// The device engine pauses reliably on a comma, but some engines still
/// spell out a bare "...".
String _ellipsisToPause(String text) =>
    text.replaceAll('...', ',').replaceAll(RegExp(r',\s*,'), ',');

/// The message as one run for the device engine: one voice for the whole
/// message, never switching mid-way.
///
/// [transliterate] mirrors the user setting: when off, Latin text is always
/// spoken as English and only real Tamil script reaches the Tamil voice.
List<SpeechRun> planSpeech(String text, {bool transliterate = true}) {
  final cleaned = normalizePunctuation(_stripUnspeakable(text));
  if (cleaned.isEmpty) return const [];

  final tamil = hasTamilScript(cleaned) ||
      (transliterate && classifyMessage(cleaned) == MessageLanguage.tamil);
  if (!tamil) {
    return [
      SpeechRun(_ellipsisToPause(cleaned), isTamil: false, original: cleaned),
    ];
  }
  final spoken = stretchBeforeEllipsis(transliterateTanglish(cleaned));
  return [
    SpeechRun(
      _ellipsisToPause(spoken),
      isTamil: true,
      original: _ellipsisToPause(cleaned),
    ),
  ];
}

/// Removes what a voice cannot usefully read: emoji, URLs, markdown noise.
String _stripUnspeakable(String s) {
  var out = s.replaceAll(RegExp(r'https?://\S+'), '');
  final buf = StringBuffer();
  for (final rune in out.runes) {
    // Emoji, pictographs, symbols and variation selectors.
    final isEmoji = (rune >= 0x1F000 && rune <= 0x1FAFF) ||
        (rune >= 0x2600 && rune <= 0x27BF) ||
        (rune >= 0xFE00 && rune <= 0xFE0F) ||
        (rune >= 0x1F1E6 && rune <= 0x1F1FF) ||
        (rune >= 0xE0020 && rune <= 0xE007F) || // flag tag characters
        rune == 0x20E3 || // keycap
        rune == 0x200D;
    if (!isEmoji) buf.writeCharCode(rune);
  }
  out = buf.toString();
  return out.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

/// [text] with emoji and links removed and punctuation tidied — what is sent
/// to Gemini.
String prepareForSpeech(String text) =>
    normalizePunctuation(_stripUnspeakable(text));

/// True when [text] has anything a voice could read out.
bool isSpeakable(String text) => _stripUnspeakable(text).trim().isNotEmpty;

/// Whether the message needs a Tamil voice at all — used to decide if the
/// engine's missing-Tamil-voice warning is worth showing.
bool needsTamilVoice(String text, {bool transliterate = true}) =>
    planSpeech(text, transliterate: transliterate).any((r) => r.isTamil);
