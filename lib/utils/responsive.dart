import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Window size classes, following the Material 3 breakpoints. These track the
/// *current* width, so a tablet reports [medium] in portrait and [expanded] in
/// landscape.
enum WindowSize { compact, medium, expanded }

extension ResponsiveContext on BuildContext {
  Size get _screen => MediaQuery.sizeOf(this);

  WindowSize get windowSize {
    final w = _screen.width;
    if (w >= 1024) return WindowSize.expanded;
    if (w >= 600) return WindowSize.medium;
    return WindowSize.compact;
  }

  /// True on any device whose *shortest* side is tablet-sized. Unlike
  /// [windowSize] this stays true in both orientations, so it is the right
  /// check for "should this be sized up", not "does a second pane fit".
  bool get isTablet => _screen.shortestSide >= 600;

  /// True when there is room to place two panes side by side.
  bool get isWide => _screen.width >= 900;

  bool get isLandscape => _screen.width > _screen.height;

  /// Upper bound for a chat bubble. The 0.72 ratio keeps the phone look; the
  /// cap stops a bubble stretching to an unreadable line length on a tablet.
  double get bubbleMaxWidth => math.min(_screen.width * 0.72, 560.0);

  /// Column count for a grid of roughly [tileWidth]-wide tiles, never fewer
  /// than [min].
  int gridCount(double tileWidth, {int min = 2}) =>
      math.max(min, (_screen.width / tileWidth).floor());

  /// Scales a phone-tuned dimension up on tablets so text and touch targets
  /// don't look lost on a large screen.
  double scaled(double compact, {double? tablet}) =>
      isTablet ? (tablet ?? compact * 1.25) : compact;
}

/// Centres [child] and caps how wide it can grow, so long-form content (lists,
/// forms, chat) stays readable on a tablet instead of stretching edge to edge.
/// On a phone the constraint is never reached, so the layout is unchanged.
class ContentWidth extends StatelessWidget {
  final double maxWidth;
  final Widget child;

  const ContentWidth({super.key, this.maxWidth = 720, required this.child});

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}
