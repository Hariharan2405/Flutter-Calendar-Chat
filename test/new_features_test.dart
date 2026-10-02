import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calendar_app/screens/chat_list_screen.dart';
import 'package:calendar_app/screens/settings_screen.dart';
import 'package:calendar_app/widgets/chat_ui.dart';
import 'package:calendar_app/widgets/gif_picker_sheet.dart';

void main() {
  group('GIPHY parsing', () {
    // Trimmed from the documented response shape.
    const body = '''{
      "data": [
        {"images": {
          "fixed_width": {"url": "https://media.giphy.com/a/200w.gif"},
          "downsized": {"url": "https://media.giphy.com/a/giphy-downsized.gif"},
          "original": {"url": "https://media.giphy.com/a/giphy.gif"}}},
        {"images": {
          "fixed_width_small": {"url": "https://media.giphy.com/b/100w.gif"},
          "original": {"url": "https://media.giphy.com/b/giphy.gif"}}},
        {"images": {}},
        {"nope": true}
      ],
      "pagination": {"total_count": 4210, "count": 4, "offset": 0}
    }''';

    test('prefers the 2 MB rendition to send and a mid-size preview', () {
      final page = parseGiphy(body);
      expect(page.gifs, hasLength(2), reason: 'malformed entries are skipped');
      expect(page.gifs[0].sendUrl, contains('downsized'));
      expect(page.gifs[0].previewUrl, contains('200w'));
    });

    test('falls back to original and the small preview', () {
      final page = parseGiphy(body);
      expect(page.gifs[1].sendUrl, contains('b/giphy.gif'));
      expect(page.gifs[1].previewUrl, contains('100w'));
    });

    test('reads the total so endless scroll knows when to stop', () {
      expect(parseGiphy(body).totalCount, 4210);
    });

    test('garbage never throws', () {
      expect(parseGiphy('not json').gifs, isEmpty);
      expect(parseGiphy('[]').gifs, isEmpty);
      expect(parseGiphy('{"data": "x"}').gifs, isEmpty);
    });

    test('errors are explained, not shown as a bare code', () {
      expect(describeGiphyError(403), contains('GIPHY_API_KEY'));
      expect(describeGiphyError(429), contains('limit'));
      expect(describeGiphyError(500), contains('500'));
    });
  });

  group('big emoji', () {
    test('1-3 emoji count, with skin tones, flags and joined emoji', () {
      expect(jumboEmojiCount('😂'), 1);
      expect(jumboEmojiCount('😂😂'), 2);
      expect(jumboEmojiCount('❤️ 🔥 😍'), 3);
      expect(jumboEmojiCount('👍🏽'), 1, reason: 'skin tone is one emoji');
      expect(jumboEmojiCount('🇮🇳'), 1, reason: 'flag is one emoji');
      expect(jumboEmojiCount('👨‍👩‍👧'), 1, reason: 'joined family is one emoji');
    });

    test('anything else stays a normal bubble', () {
      expect(jumboEmojiCount('😂😂😂😂'), 0, reason: 'more than 3');
      expect(jumboEmojiCount('ok 👍'), 0);
      expect(jumboEmojiCount('சரி 😂'), 0);
      expect(jumboEmojiCount(''), 0);
      expect(jumboEmojiCount('123'), 0);
    });

    test('fewer emoji are drawn larger', () {
      expect(jumboEmojiSize(1), greaterThan(jumboEmojiSize(2)));
      expect(jumboEmojiSize(2), greaterThan(jumboEmojiSize(3)));
    });
  });

  test('cache sizes read naturally', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(12 * 1024 * 1024), '12.0 MB');
    expect(formatBytes(250 * 1024 * 1024), '250 MB');
  });

  group('tablet split view', () {
    testWidgets('inside the split view a tile opens the chat in the pane',
        (tester) async {
      String? openedId;
      await tester.pumpWidget(MaterialApp(
        home: ChatPaneScope(
          selectedId: null,
          open: (id, _) => openedId = id,
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => ChatPaneScope.openOrPush(ctx,
                  id: 'c1', build: (embedded) => Text('embedded=$embedded')),
              child: const Text('tile'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('tile'));
      await tester.pumpAndSettle();
      expect(openedId, 'c1');
      expect(find.text('embedded=true'), findsNothing,
          reason: 'the pane, not a new page, shows it');
    });

    testWidgets('on a phone a tile pushes the chat as its own page',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => ChatPaneScope.openOrPush(ctx,
                id: 'c1', build: (embedded) => Text('embedded=$embedded')),
            child: const Text('tile'),
          ),
        ),
      ));
      await tester.tap(find.text('tile'));
      await tester.pumpAndSettle();
      expect(find.text('embedded=false'), findsOneWidget);
    });

    testWidgets('the open chat is reported as selected', (tester) async {
      String? seen;
      await tester.pumpWidget(MaterialApp(
        home: ChatPaneScope(
          selectedId: 'c9',
          open: (_, __) {},
          child: Builder(builder: (ctx) {
            seen = ChatPaneScope.selectedOf(ctx);
            return const SizedBox();
          }),
        ),
      ));
      expect(seen, 'c9');
    });
  });
}
