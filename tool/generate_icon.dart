import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  const s = 1024;

  final bg    = img.ColorRgb8(92,  53,  209); // #5C35D1 — brand purple
  final hdr   = img.ColorRgb8(52,  18,  158); // darker purple for header
  final white = img.ColorRgb8(255, 255, 255);
  final dot   = img.ColorRgb8(190, 175, 240); // lavender day dots
  final ring  = img.ColorRgb8(120,  95, 210); // medium purple ring tabs

  final im = img.Image(width: s, height: s);

  // 1. Background
  img.fill(im, color: bg);

  // 2. Ring tabs — drawn before card so card overlaps their lower half,
  //    leaving only the hooks visible above the card top edge.
  _rrect(im, 346, 102, 402, 262, 28, ring);
  _rrect(im, 622, 102, 678, 262, 28, ring);

  // 3. White card body
  _rrect(im, 148, 186, 876, 872, 80, white);

  // 4. Dark-purple header bar (rounded only at top, straight at bottom)
  _rrectTop(im, 148, 186, 876, 388, 80, hdr);

  // 5. Week-label row — 7 small pill shapes just below header
  for (var i = 0; i < 7; i++) {
    final cx = 214 + i * 92;
    _rrect(im, cx - 23, 404, cx + 23, 424, 8, dot);
  }

  // 6. Day grid — 31 days, month starts on Sunday (col 0)
  for (var day = 1; day <= 31; day++) {
    final idx = day - 1; // 0-based
    final col = idx % 7;
    final row = idx ~/ 7;
    final cx  = 214 + col * 92 + 46;
    final cy  = 450 + row * 82 + 41;

    if (day == 17) {
      // "Today" highlight
      img.fillCircle(im, x: cx, y: cy, radius: 38, color: bg);
      img.fillCircle(im, x: cx, y: cy, radius: 13, color: white);
    } else {
      img.fillCircle(im, x: cx, y: cy, radius: 15, color: dot);
    }
  }

  final outPath = 'assets/icon/app_icon.png';
  File(outPath).writeAsBytesSync(img.encodePng(im));
  print('Icon saved to $outPath');
}

// Full rounded rectangle (all 4 corners)
void _rrect(img.Image im, int x1, int y1, int x2, int y2, int r, img.Color c) {
  img.fillRect(im, x1: x1 + r, y1: y1,     x2: x2 - r, y2: y2,     color: c);
  img.fillRect(im, x1: x1,     y1: y1 + r, x2: x1 + r, y2: y2 - r, color: c);
  img.fillRect(im, x1: x2 - r, y1: y1 + r, x2: x2,     y2: y2 - r, color: c);
  img.fillCircle(im, x: x1 + r, y: y1 + r, radius: r, color: c);
  img.fillCircle(im, x: x2 - r, y: y1 + r, radius: r, color: c);
  img.fillCircle(im, x: x1 + r, y: y2 - r, radius: r, color: c);
  img.fillCircle(im, x: x2 - r, y: y2 - r, radius: r, color: c);
}

// Rounded only at the top two corners
void _rrectTop(img.Image im, int x1, int y1, int x2, int y2, int r, img.Color c) {
  img.fillRect(im, x1: x1 + r, y1: y1,     x2: x2 - r, y2: y2, color: c);
  img.fillRect(im, x1: x1,     y1: y1 + r, x2: x1 + r, y2: y2, color: c);
  img.fillRect(im, x1: x2 - r, y1: y1 + r, x2: x2,     y2: y2, color: c);
  img.fillCircle(im, x: x1 + r, y: y1 + r, radius: r, color: c);
  img.fillCircle(im, x: x2 - r, y: y1 + r, radius: r, color: c);
}
