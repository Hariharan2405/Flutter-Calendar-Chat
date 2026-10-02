import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:calendar_app/screens/profile_photo_crop_screen.dart';

void main() {
  const crop = 300.0;

  group('whole photo is visible at zoom 1', () {
    test('a landscape photo fits inside the crop square', () {
      // 4000x3000 — the old cover-fit cropped the sides away immediately.
      const g = CropGeometry(
          cropSize: crop, imageWidth: 4000, imageHeight: 3000);
      final shown = g.displayedSize(1.0);
      expect(shown.width, closeTo(crop, 0.001));
      expect(shown.height, lessThan(crop));
      expect(shown.height, closeTo(225, 0.001));
    });

    test('a portrait photo fits inside the crop square', () {
      const g = CropGeometry(
          cropSize: crop, imageWidth: 3000, imageHeight: 4000);
      final shown = g.displayedSize(1.0);
      expect(shown.height, closeTo(crop, 0.001));
      expect(shown.width, lessThan(crop));
    });

    test('an extreme panorama still fits entirely', () {
      const g = CropGeometry(
          cropSize: crop, imageWidth: 8000, imageHeight: 1000);
      final shown = g.displayedSize(1.0);
      expect(shown.width, lessThanOrEqualTo(crop + 0.001));
      expect(shown.height, lessThanOrEqualTo(crop + 0.001));
    });

    test('a square photo exactly fills the square', () {
      const g = CropGeometry(
          cropSize: crop, imageWidth: 1000, imageHeight: 1000);
      final shown = g.displayedSize(1.0);
      expect(shown.width, closeTo(crop, 0.001));
      expect(shown.height, closeTo(crop, 0.001));
    });
  });

  group('panning bounds', () {
    test('cannot pan at all while the whole photo is visible', () {
      const g = CropGeometry(
          cropSize: crop, imageWidth: 4000, imageHeight: 3000);
      expect(g.clampOffset(const Offset(500, 500), 1.0), Offset.zero);
      expect(g.clampOffset(const Offset(-500, -500), 1.0), Offset.zero);
    });

    test('panning opens up along the axis that overflows when zoomed', () {
      const g = CropGeometry(
          cropSize: crop, imageWidth: 4000, imageHeight: 3000);
      // At 2x a landscape photo is 600x450 inside a 300 box.
      final clamped = g.clampOffset(const Offset(1000, 1000), 2.0);
      expect(clamped.dx, closeTo(150, 0.001));
      expect(clamped.dy, closeTo(75, 0.001));
    });

    test('the photo can never be dragged off the crop square', () {
      const g = CropGeometry(
          cropSize: crop, imageWidth: 3000, imageHeight: 4000);
      for (final zoom in [1.0, 1.5, 3.0, 8.0]) {
        final c = g.clampOffset(const Offset(99999, -99999), zoom);
        final shown = g.displayedSize(zoom);
        // Clamped offset must keep the image covering the square wherever it
        // overflows, i.e. never exceed the overflow on that axis.
        expect(c.dx.abs(),
            lessThanOrEqualTo((shown.width - crop).abs() / 2 + 0.001));
        expect(c.dy.abs(),
            lessThanOrEqualTo((shown.height - crop).abs() / 2 + 0.001));
      }
    });
  });

  group('preview and saved output agree', () {
    test('the output rect is the preview rect scaled by the ratio', () {
      const g = CropGeometry(
          cropSize: crop, imageWidth: 4000, imageHeight: 3000);
      const offset = Offset(20, -10);
      const zoom = 2.5;
      const out = 768.0;
      final ratio = out / crop;

      final preview = g.destRect(
          scale: zoom, offset: offset, canvasSize: crop, ratio: 1.0);
      final saved = g.destRect(
          scale: zoom, offset: offset, canvasSize: out, ratio: ratio);

      expect(saved.width, closeTo(preview.width * ratio, 0.001));
      expect(saved.height, closeTo(preview.height * ratio, 0.001));
      // Same point of the photo sits at the centre of both canvases.
      expect((saved.center.dx - out / 2),
          closeTo((preview.center.dx - crop / 2) * ratio, 0.001));
      expect((saved.center.dy - out / 2),
          closeTo((preview.center.dy - crop / 2) * ratio, 0.001));
    });

    test('zoom is clamped to the documented range', () {
      expect(CropGeometry.minZoom, 1.0);
      expect(CropGeometry.maxZoom, 8.0);
    });
  });
}
