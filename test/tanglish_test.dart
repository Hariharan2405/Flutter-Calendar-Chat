import 'package:flutter_test/flutter_test.dart';
import 'package:calendar_app/utils/tanglish.dart';

void main() {
  group('classification', () {
    test('plain English stays English', () {
      for (final s in [
        'Hello, are you coming to the meeting tomorrow?',
        'I sent the file just now',
        'ok done',
      ]) {
        final runs = planSpeech(s);
        expect(runs.every((r) => !r.isTamil), isTrue, reason: s);
      }
    });

    test('Tanglish routes to the Tamil voice', () {
      for (final s in [
        'epdi iruka',
        'naan innaiku varen',
        'enna panra da',
        'romba nalla iruku',
        'veetuku poitu call panren',
      ]) {
        final runs = planSpeech(s);
        expect(runs.any((r) => r.isTamil), isTrue, reason: s);
      }
    });

    test('Tamil script routes to the Tamil voice untouched', () {
      final runs = planSpeech('வணக்கம் எப்படி இருக்கீங்க');
      expect(runs.single.isTamil, isTrue);
      expect(runs.single.text, 'வணக்கம் எப்படி இருக்கீங்க');
    });

    test('transliteration can be disabled', () {
      final runs = planSpeech('epdi iruka', transliterate: false);
      expect(runs.single.isTamil, isFalse);
      expect(runs.single.text, 'epdi iruka');
    });
  });

  group('transliteration', () {
    test('lexicon words map exactly', () {
      expect(transliterateTanglish('naan'), 'நான்');
      expect(transliterateTanglish('epdi iruka'), 'எப்படி இருக்கா');
      expect(transliterateTanglish('vanakkam'), 'வணக்கம்');
      expect(transliterateTanglish('romba nalla'), 'ரொம்ப நல்ல');
    });

    test('unknown words fall through to the rules and stay Tamil script', () {
      final out = transliterateTanglish('kadhavu thirandhuchu');
      expect(hasTamilScript(out), isTrue);
      expect(RegExp(r'[a-z]').hasMatch(out), isFalse);
    });

    test('punctuation is preserved', () {
      expect(transliterateTanglish('enna?'), 'என்ன?');
    });

    test('gemination produces a doubled consonant', () {
      expect(transliterateTanglish('pattu'), 'பட்டு');
    });
  });

  group('cleanup', () {
    test('emoji and URLs are dropped', () {
      final runs = planSpeech('check this https://x.com/abc 😀🔥');
      expect(runs.single.text.contains('http'), isFalse);
      expect(runs.single.text.contains('😀'), isFalse);
    });

    test('emoji-only message is not speakable', () {
      expect(isSpeakable('😀🔥👍'), isFalse);
      expect(isSpeakable('hi'), isTrue);
    });
  });

  realWorldChecks();

  group('offline fallback', () {
    // Regression: with no Tamil voice installed, a Tanglish run was handed to
    // the English engine as Tamil script, which it cannot pronounce — so most
    // sentences came out silent. The run must keep what the user typed.
    test('a Tanglish run keeps the Latin text the user typed', () {
      final run = planSpeech('naan veetuku poren').single;
      expect(run.isTamil, isTrue);
      expect(hasTamilScript(run.text), isTrue);
      expect(run.original, 'naan veetuku poren');
    });

    test('merged runs keep the merged original text', () {
      final run = planSpeech('enna da. naan varen.').single;
      expect(run.original, 'enna da. naan varen.');
    });

    test('English runs are unchanged either way', () {
      final run = planSpeech('See you tomorrow').single;
      expect(run.text, run.original);
    });
  });

  group('one voice per message', () {
    // Regression: deciding per sentence switched to the English voice for
    // "But vendam." and read the Tamil word in English.
    test('English words inside Tanglish stay in the Tamil voice', () {
      final run = planSpeech('ithu enakku ok. But vendam.').single;
      expect(run.isTamil, isTrue);
      expect(run.text, contains('வேண்டாம்'));
      expect(run.text, contains('பட்'));
      expect(RegExp('[A-Za-z]').hasMatch(run.text), isFalse);
    });

    test('a mixed message is read entirely in Tamil', () {
      final runs = planSpeech('The meeting is done. naan veetuku poren.');
      expect(runs, hasLength(1));
      expect(runs.single.isTamil, isTrue);
    });

    test('an English message stays one English run', () {
      final runs = planSpeech('Okay... see you tomorrow then');
      expect(runs, hasLength(1));
      expect(runs.single.isTamil, isFalse);
    });
  });

  group('classifyMessage', () {
    test('Tamil anywhere means Tamil everywhere', () {
      expect(classifyMessage('ithu enakku ok. But vendam.'),
          MessageLanguage.tamil);
      expect(classifyMessage('வணக்கம் see you'), MessageLanguage.tamil);
    });

    test('known English words skip the rewrite', () {
      expect(classifyMessage('Okay... see you tomorrow then'),
          MessageLanguage.english);
      expect(classifyMessage('Can you send me the report by 5pm?'),
          MessageLanguage.english);
    });

    test('unknown words are left for Gemini to decide', () {
      expect(classifyMessage('kalakkal pa'), isNot(MessageLanguage.english));
    });
  });

  group('punctuation', () {
    test('runs of dots become one ellipsis', () {
      expect(normalizePunctuation('seri da...... naan'), 'seri da... naan');
      expect(normalizePunctuation('Hmm. . . . ok'), 'Hmm... ok');
      expect(normalizePunctuation('wait…… ok'), 'wait... ok');
    });

    test('repeated marks collapse to one', () {
      expect(normalizePunctuation('enna solra nee???'), 'enna solra nee?');
      expect(normalizePunctuation('super!!!'), 'super!');
    });

    test('the offline voice never sees dots to spell out', () {
      for (final t in ['seri da...... naan varen', 'Okay.......... bye']) {
        expect(planSpeech(t).single.text.contains('.'), isFalse, reason: t);
      }
    });
  });

  group('stretching before an ellipsis', () {
    test('short vowels lengthen, long ones stay', () {
      expect(stretchTamilWord('சரி'), 'சரீ');
      expect(stretchTamilWord('அது'), 'அதூ');
      expect(stretchTamilWord('டா'), 'டா');
      expect(stretchTamilWord('வேண்டாம்'), 'வேண்டாம்');
    });

    test('a bare consonant gains a long a', () {
      expect(stretchTamilWord('வேற'), 'வேறா');
    });

    test('only the word right before the ellipsis is stretched', () {
      expect(stretchBeforeEllipsis('சரி டா... நான்'), 'சரி டா... நான்');
      expect(stretchBeforeEllipsis('நான் சரி... ஓகே'), 'நான் சரீ... ஓகே');
    });
  });
}

/// Realistic traffic, kept separate so a regression points straight at the
/// classifier rather than at the transliteration rules.
void realWorldChecks() {
  group('real-world English (must not go to the Tamil voice)', () {
    const english = [
      'Can you send me the report by 5pm?',
      'Thanks, got it',
      'Hello',
      'I am in a meeting right now, will call you back',
      'Please check your email',
      'Good morning',
      'ok',
      'The bus is late again today',
      'What time is the call tomorrow',
      'Sorry for the delay',
    ];
    for (final s in english) {
      test('"$s"', () {
        expect(planSpeech(s).any((r) => r.isTamil), isFalse);
      });
    }
  });

  group('real-world Tanglish (must go to the Tamil voice)', () {
    const tanglish = [
      'enna da machan epdi iruka',
      'naan office la iruken',
      'innaiku evening vanga',
      'saapta illa',
      'romba thanks da',
      'neenga eppo varuven',
      'adhu theriyala',
      'seri naan poren',
      'veetuku vandhu paaru',
      'enna panna pogudhu nu theriyala',
    ];
    for (final s in tanglish) {
      test('"$s"', () {
        final runs = planSpeech(s);
        expect(runs.any((r) => r.isTamil), isTrue);
        // Whatever reaches the Tamil voice must be Tamil script, otherwise the
        // engine applies English phonetics to Latin letters.
        for (final r in runs.where((r) => r.isTamil)) {
          expect(RegExp(r'[A-Za-z]').hasMatch(r.text), isFalse,
              reason: 'untransliterated Latin left in "${r.text}"');
        }
      });
    }
  });
}
