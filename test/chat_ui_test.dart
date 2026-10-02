import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calendar_app/widgets/chat_ui.dart';

/// Renders [child] at a typical phone width, in a constrained bubble column
/// like the chat screens use. Any overflow or layout error fails the test.
Future<void> pumpInChat(WidgetTester tester, Widget child,
    {double width = 390}) async {
  tester.view.physicalSize = Size(width * 3, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width * 0.78),
              child: child,
            ),
          ),
        ],
      ),
    ),
  ));
  await tester.pump();
}

// 1x1 transparent PNG, for a decodable inline thumbnail.
const _pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  group('bubbles', () {
    testWidgets('a short text bubble hugs its text', (tester) async {
      await pumpInChat(
        tester,
        BubbleFrame(
          isMe: true,
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Text('ok'),
          ),
        ),
      );
      final size = tester.getSize(find.byType(BubbleFrame));
      expect(size.width, lessThan(100), reason: 'should not stretch to max');
    });

    testWidgets('a long message wraps instead of overflowing', (tester) async {
      await pumpInChat(
        tester,
        BubbleFrame(
          isMe: false,
          tail: false,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text('நாளைக்கு லீவா? சொல்லு டா ' * 12),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a named-colour bubble uses that colour', (tester) async {
      await pumpInChat(
        tester,
        const BubbleFrame(isMe: false, color: Colors.green, child: Text('hi')),
      );
      final box = tester.widget<DecoratedBox>(find.descendant(
          of: find.byType(BubbleFrame), matching: find.byType(DecoratedBox)));
      final deco = box.decoration as BoxDecoration;
      expect(deco.color, Colors.green);
      expect(deco.gradient, isNull);
    });

    test('only the tail corner is pointed', () {
      final mine = ChatStyle.bubbleRadius(isMe: true);
      expect(mine.bottomRight.x, ChatStyle.tail);
      expect(mine.bottomLeft.x, ChatStyle.radius);
      final grouped = ChatStyle.bubbleRadius(isMe: true, tail: false);
      expect(grouped.bottomRight.x, ChatStyle.radius);
    });
  });

  group('reply quote', () {
    testWidgets('renders with an inline thumbnail at phone width',
        (tester) async {
      await pumpInChat(
        tester,
        ReplyQuote(
          label: 'Harry',
          text: '🎥 Status ${'long caption ' * 10}',
          isMe: true,
          thumbBase64: _pixel,
          isVideo: true,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
    });

    testWidgets('renders text-only without a thumbnail', (tester) async {
      await pumpInChat(
        tester,
        const ReplyQuote(label: 'You', text: 'enna da', isMe: false),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a corrupt inline thumbnail is ignored, not a crash',
        (tester) async {
      await pumpInChat(
        tester,
        const ReplyQuote(
            label: 'X', text: 'y', isMe: false, thumbBase64: '%%%not-base64'),
      );
      expect(tester.takeException(), isNull);
    });

    test('recognises video previews by their label', () {
      expect(ReplyQuote.looksLikeVideo('🎥 Video'), isTrue);
      expect(ReplyQuote.looksLikeVideo('🎬 Video'), isTrue);
      expect(ReplyQuote.looksLikeVideo('📷 Photo'), isFalse);
    });

    test('inline thumbnails decode', () {
      expect(base64Decode(_pixel), isNotEmpty);
    });
  });

  group('video preview', () {
    testWidgets('a video without a still shows a placeholder, not black',
        (tester) async {
      await pumpInChat(
        tester,
        const VideoPreview(
          videoUrl: 'https://example.com/v.mp4',
          isMe: false,
          durationMs: 75000,
        ),
      );
      // Frame-making fails in tests (no device); the placeholder must hold.
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('1:15'), findsOneWidget);
    });

    test('durations format as m:ss', () {
      expect(VideoPreview.formatDuration(5000), '0:05');
      expect(VideoPreview.formatDuration(75000), '1:15');
      expect(VideoPreview.formatDuration(600000), '10:00');
    });
  });

  group('meta and dates', () {
    testWidgets('time over media gets its own dark backing', (tester) async {
      await pumpInChat(
        tester,
        BubbleMeta(time: DateTime(2026, 10, 2, 13, 33), isMe: true, onMedia: true),
      );
      expect(find.text('1:33 PM'), findsOneWidget);
      expect(find.byType(Container), findsWidgets);
    });

    testWidgets('date pill says Today for today', (tester) async {
      await pumpInChat(tester, DatePill(date: DateTime.now()));
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('date pill says Yesterday', (tester) async {
      await pumpInChat(
          tester,
          DatePill(
              date: DateTime.now().subtract(const Duration(days: 1))));
      expect(find.text('Yesterday'), findsOneWidget);
    });
  });

  testWidgets('header avatar shows an initial and an online dot',
      (tester) async {
    await pumpInChat(
      tester,
      const HeaderAvatar(photoUrl: null, name: 'harry', online: true),
    );
    expect(find.text('H'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Regression: the header gradient painted at zero size, leaving a white
  // bar with an invisible white title.
  testWidgets('the header gradient fills the whole app bar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          flexibleSpace: const ChatHeaderBackground(),
          title: const Text('Messages'),
        ),
      ),
    ));
    final bar = tester.getSize(find.byType(AppBar));
    final paint = tester.getSize(find.descendant(
        of: find.byType(ChatHeaderBackground),
        matching: find.byType(DecoratedBox)));
    expect(paint.height, greaterThan(0));
    expect(paint.width, bar.width);
    expect(paint.height, bar.height);
  });

  test('reply labels name you or the sender', () {
    expect(
        replyLabel(
            replyToSenderId: 'me', currentUid: 'me', otherName: 'Harry'),
        'You');
    expect(
        replyLabel(
            replyToSenderId: 'h', currentUid: 'me', otherName: 'Harry'),
        'Harry');
  });
}
