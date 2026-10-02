import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:calendar_app/utils/shared_stream.dart';

void main() {
  group('SharedStream', () {
    test('subscribes upstream once no matter how many listeners', () async {
      var builds = 0;
      final ctrl = StreamController<int>.broadcast();
      final shared = SharedStream<int>(() {
        builds++;
        return ctrl.stream;
      });

      final a = <int>[];
      final b = <int>[];
      final subA = shared.stream().listen(a.add);
      final subB = shared.stream().listen(b.add);
      await Future<void>.delayed(Duration.zero);

      ctrl.add(1);
      await Future<void>.delayed(Duration.zero);

      expect(builds, 1, reason: 'upstream must be built exactly once');
      expect(a, [1]);
      expect(b, [1]);

      await subA.cancel();
      await subB.cancel();
      await ctrl.close();
    });

    test('a new listener replays the latest value immediately', () async {
      final ctrl = StreamController<int>.broadcast();
      final shared = SharedStream<int>(() => ctrl.stream);

      final first = shared.stream().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      ctrl.add(7);
      await Future<void>.delayed(Duration.zero);

      // Arrives after the value was emitted — it must still see it, rather
      // than waiting for the next upstream change.
      final late = await shared.stream().first;
      expect(late, 7);
      expect(shared.lastValue, 7);

      await first.cancel();
      await ctrl.close();
    });

    test('survives its listener count dropping to zero', () async {
      // This is the regression: asAsBroadcastStream() closed for good once the
      // last listener left, so re-entering a screen hung on a spinner.
      final ctrl = StreamController<int>.broadcast();
      final shared = SharedStream<int>(() => ctrl.stream);

      final sub = shared.stream().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      ctrl.add(1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel(); // screen closed

      ctrl.add(2);
      await Future<void>.delayed(Duration.zero);

      // Screen reopened.
      final seen = <int>[];
      final again = shared.stream().listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      expect(seen, isNotEmpty, reason: 'stream went dead after last cancel');
      expect(seen.first, 2, reason: 'should replay the newest value');

      ctrl.add(3);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [2, 3], reason: 'must keep receiving after resubscribe');

      await again.cancel();
      await ctrl.close();
    });

    test('errors reach listeners', () async {
      final ctrl = StreamController<int>.broadcast();
      final shared = SharedStream<int>(() => ctrl.stream);
      final errors = <Object>[];
      final sub = shared.stream().listen((_) {}, onError: errors.add);
      await Future<void>.delayed(Duration.zero);

      ctrl.addError(StateError('boom'));
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));

      await sub.cancel();
      await ctrl.close();
    });
  });

  group('KeyedSharedStreams', () {
    test('one upstream per key, reused across calls', () async {
      final built = <String, int>{};
      final ctrls = <String, StreamController<String>>{};
      final keyed = KeyedSharedStreams<String, String>((key) {
        built[key] = (built[key] ?? 0) + 1;
        return (ctrls[key] ??= StreamController<String>.broadcast()).stream;
      });

      final a1 = keyed.stream('a').listen((_) {});
      final a2 = keyed.stream('a').listen((_) {});
      final b1 = keyed.stream('b').listen((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(built['a'], 1, reason: 'repeated calls must share one upstream');
      expect(built['b'], 1);

      ctrls['a']!.add('x');
      await Future<void>.delayed(Duration.zero);
      expect(keyed.lastValue('a'), 'x');
      expect(keyed.lastValue('b'), isNull, reason: 'keys must not cross over');

      await a1.cancel();
      await a2.cancel();
      await b1.cancel();
      for (final c in ctrls.values) {
        await c.close();
      }
    });
  });
}
