import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// Decode budgets for network images.
///
/// Flutter decodes an image at its stored resolution unless told otherwise, and
/// holds the decoded bitmap — not the JPEG — in a cache capped at ~100 MB. A
/// profile photo is stored at 512px, so a 48px avatar was costing
/// 512×512×4 ≈ 1 MB instead of ~20 KB; a chat photo is stored at 1600px, so one
/// image bubble cost 1600×1600×4 ≈ 10 MB. A chat with a dozen photos in the
/// scroll window therefore blew the cache, and scrolling back re-decoded
/// everything from disk — which is what makes a list feel sticky.
///
/// Giving the decoder a target size fixes that at the source: less RAM, less
/// CPU per frame, and far fewer cache evictions.
///
/// Sizes here are in logical pixels and are scaled by [_maxDpr]. A fixed cap is
/// used rather than the real device ratio so these need no `BuildContext`.
/// 3.5 covers essentially every Android screen, so avatars stay sharp on the
/// densest panels; over-allocating on a 2x screen is still an order of
/// magnitude better than decoding full-size, because the cost is quadratic in
/// the side length and these targets are small to begin with.
const double _maxDpr = 3.5;

/// Physical pixels to decode for something [logicalSide] wide on screen.
int decodePx(double logicalSide) => (logicalSide * _maxDpr).ceil();

/// Image provider for a circular avatar of the given [radius].
ImageProvider avatarImage(String url, {required double radius}) {
  final px = decodePx(radius * 2);
  return CachedNetworkImageProvider(url, maxWidth: px, maxHeight: px);
}

/// Image provider for a non-circular thumbnail [side] logical pixels wide.
ImageProvider thumbImage(String url, {required double side}) {
  final px = decodePx(side);
  return CachedNetworkImageProvider(url, maxWidth: px, maxHeight: px);
}

/// Decode width for a photo shown inside a chat bubble.
///
/// Bubbles are width-capped well under the screen width, so this is generous
/// enough to stay sharp while cutting the decode by roughly an order of
/// magnitude versus the stored 1600px.
const int kBubbleImageDecodeWidth = 720;

/// Decode width for a status/story thumbnail in a list row.
const int kStatusThumbDecodeWidth = 160;
