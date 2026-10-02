import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:calendar_app/services/gemini_speech.dart';
import 'package:calendar_app/services/tts_service.dart';

void main() {
  group('needsPlan', () {
    test('Tamil script alone skips the rewrite call', () {
      expect(GeminiSpeech.needsPlan('எப்படி இருக்கீங்க?'), isFalse);
      expect(GeminiSpeech.needsPlan('12:30 !'), isFalse);
    });

    test('anything with English letters is rewritten first', () {
      // Tanglish and English look identical without judgement.
      expect(GeminiSpeech.needsPlan('epdi iruka'), isTrue);
      expect(GeminiSpeech.needsPlan('See you at 5'), isTrue);
      expect(GeminiSpeech.needsPlan('வணக்கம் da'), isTrue);
    });
  });

  group('response parsing', () {
    Map<String, dynamic> interaction(List<Map<String, dynamic>> content,
            {String type = 'model_output'}) =>
        {
          'steps': [
            {'type': 'user_input', 'content': [
              {'type': 'text', 'text': 'IGNORED - this is the prompt'},
            ]},
            {'type': type, 'content': content},
          ],
        };

    test('reads model text and ignores the echoed input', () {
      final json = interaction([
        {'type': 'text', 'text': '{"speech_text":'},
        {'type': 'text', 'text': ' "நான் வரேன்"}'},
      ]);
      expect(GeminiSpeech.textFromInteraction(json),
          '{"speech_text": "நான் வரேன்"}');
    });

    test('reads the last audio part', () {
      final first = base64Encode([1, 2]);
      final last = base64Encode([3, 4, 5]);
      final json = interaction([
        {'type': 'audio', 'data': first},
        {'type': 'audio', 'data': last},
      ]);
      expect(GeminiSpeech.audioFromInteraction(json), last);
    });

    test('missing or malformed responses yield null, never throw', () {
      expect(GeminiSpeech.textFromInteraction({}), isNull);
      expect(GeminiSpeech.textFromInteraction({'steps': 'x'}), isNull);
      expect(GeminiSpeech.audioFromInteraction({'steps': [
        {'type': 'model_output', 'content': [{'type': 'text', 'text': 'hi'}]},
      ]}), isNull);
      expect(GeminiSpeech.textFromInteraction(
          interaction([{'type': 'text', 'text': 'x'}], type: 'thought')),
          isNull);
    });
  });

  group('parsePlan', () {
    test('extracts and trims speech_text', () {
      expect(GeminiSpeech.parsePlan('{"speech_text": "  நான் வரேன் "}'),
          'நான் வரேன்');
    });

    test('rejects empty, missing or invalid plans', () {
      expect(GeminiSpeech.parsePlan('{"speech_text": "  "}'), isNull);
      expect(GeminiSpeech.parsePlan('{"other": "x"}'), isNull);
      expect(GeminiSpeech.parsePlan('not json'), isNull);
      expect(GeminiSpeech.parsePlan('["speech_text"]'), isNull);
    });
  });

  group('characters', () {
    test('every character has a distinct voice and a style', () {
      final voices = VoiceCharacter.values.map((c) => c.geminiVoice).toSet();
      expect(voices.length, VoiceCharacter.values.length);
      for (final c in VoiceCharacter.values) {
        expect(c.geminiStyle, isNotEmpty);
      }
    });
  });

  group('classifyError', () {
    test('success is not an error', () {
      expect(GeminiSpeech.classifyError(200, '{}'), isNull);
    });

    test('503 and timeouts-as-504 are "busy", which rests the model briefly',
        () {
      // The exact 503 body the free tier returned during testing.
      const body = '{"error":{"message":"gemini-3.8-flash is currently '
          'experiencing high demand","code":"service_unavailable"}}';
      expect(GeminiSpeech.classifyError(503, body),
          isA<GeminiBusyException>());
      expect(GeminiSpeech.classifyError(504, ''), isA<GeminiBusyException>());
    });

    test('a per-minute 429 uses the suggested wait', () {
      const body = '{"error":{"code":429,"details":[{"@type":'
          '"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"28s"}]}}';
      final e = GeminiSpeech.classifyError(429, body)! as GeminiQuotaException;
      expect(e.daily, isFalse);
      expect(e.restFor, const Duration(seconds: 28));
    });

    test('a per-day 429 with no stated wait rests an hour', () {
      const body = '{"error":{"code":429,"details":[{"violations":'
          '[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]}}';
      final e = GeminiSpeech.classifyError(429, body)! as GeminiQuotaException;
      expect(e.daily, isTrue);
      expect(e.restFor, const Duration(hours: 1));
    });

    // The exact body the free tier returned when the daily limit was hit.
    test('the real daily-limit message rests until Gemini says it resets', () {
      const body = '{"error":{"message":"Rate limit exceeded for model '
          'gemini-3.8-flash-tts (limit: 10 requests per day on Free Tier). '
          'Please retry in 14h45m30s or upgrade your tier at '
          'https://ai.dev/rate-limit.","code":"too_many_requests"}}';
      final e = GeminiSpeech.classifyError(429, body)! as GeminiQuotaException;
      expect(e.daily, isTrue);
      expect(e.restFor,
          const Duration(hours: 14, minutes: 45, seconds: 30));
    });

    test('the real per-minute message rests only seconds', () {
      const body = '{"error":{"message":"Rate limit exceeded for model '
          'gemini-3.8-flash-tts (limit: 3 requests per minute on Free Tier). '
          'Please retry in 41.2s.","code":"too_many_requests"}}';
      final e = GeminiSpeech.classifyError(429, body)! as GeminiQuotaException;
      expect(e.daily, isFalse);
      expect(e.restFor, const Duration(milliseconds: 41200));
    });

    test('retry-after parsing handles each unit alone', () {
      expect(GeminiSpeech.parseRetryAfter('retry in 2h'), const Duration(hours: 2));
      expect(GeminiSpeech.parseRetryAfter('Retry in 5m'), const Duration(minutes: 5));
      expect(GeminiSpeech.parseRetryAfter('nothing here'), isNull);
    });

    test('a 429 with no detail still rests briefly, not for half an hour', () {
      final e = GeminiSpeech.classifyError(429, '')! as GeminiQuotaException;
      expect(e.restFor, const Duration(minutes: 1));
    });

    test('other failures are plain errors', () {
      final e = GeminiSpeech.classifyError(400, 'bad');
      expect(e, isA<GeminiException>());
      expect(e, isNot(isA<GeminiBusyException>()));
      expect(e, isNot(isA<GeminiQuotaException>()));
    });
  });

  test('each step has a backup model', () {
    expect(GeminiSpeech.planModels.length, greaterThanOrEqualTo(2));
    expect(GeminiSpeech.voiceModels.length, greaterThanOrEqualTo(2));
    // Thinking adds seconds before every rewrite; keep it minimal.
    expect(GeminiSpeech.planModels.first.thinking, 'minimal');
  });

  test('the plan schema requires speech_text', () {
    expect(GeminiSpeech.planSchema['required'], ['speech_text']);
  });

  test('a test build without a key reports Gemini as unavailable', () {
    // Tests run without --dart-define, so this documents the fallback path.
    expect(GeminiSpeech.isConfigured, isFalse);
  });
}
