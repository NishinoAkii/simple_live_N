# canvas_danmaku 0.2.7 — SimpleLive patches

Copied from pub.dev `canvas_danmaku` 0.2.7 (MIT, see LICENSE; the example app
is left out). Two sets of changes, marked `SimpleLive:` in the code.

## Releasing native objects

These release native text and picture objects as soon as they are no longer
needed, instead of leaving them to the garbage collector:

- `DanmakuItem.dispose()` / `disposeAll()` / `removeWhere()`: dispose the
  cached `Paragraph`s (and a special item's `TextPainter`).
- `DanmakuScreen`: uses them when items leave the screen, are cleared, are
  hidden by an option change, when the font size changes (paragraphs are
  rebuilt) and when the screen is disposed; drops the paragraphs of an item
  that found no free track; disposes the measuring `TextPainter`s.
- `ScrollDanmakuPainter` / `SpecialDanmakuPainter`: dispose the batch
  `Picture` after drawing it (one is recorded every frame).

Why: an item stays on screen for several seconds, so its Dart wrapper gets
promoted to the old generation and its native paragraphs were only freed by
an old-generation collection. With busy chat this made the process grow by
tens of MB per minute between collections.

## Emote images (表情图片)

Danmaku can mix text with small images (chat emotes such as Bilibili `[doge]`,
YouTube custom emoji, Twitch emotes), or be a single big sticker:

- `DanmakuSegment` (text or `ui.Image`) and `DanmakuContentItem.segments` /
  `.sticker`. A content item without segments behaves exactly as before.
- `Utils.generateParagraph` / `generateStrokeParagraph` lay out image segments
  as paragraph placeholders (`addPlaceholder`, height `fontSize * 1.15`, or the
  sticker height); `Utils.drawImages` draws the images into the placeholder
  boxes (`getBoxesForPlaceholders`, cached per item as `imageRects` and reset
  whenever the paragraph is rebuilt). All three painters call it right after
  drawing the paragraph.
- `DanmakuScreen.addDanmaku`: an item that will show images first `clone()`s
  them, so it owns its own handles (`DanmakuItem.images`); they are disposed in
  `DanmakuItem.dispose()` and, when no track had room, right away. The caller's
  images can therefore be evicted from its cache while the danmaku is still on
  screen. If cloning fails (the caller already disposed an image) the item is
  shown as plain text.
- A scrolling sticker occupies two tracks (`DanmakuItem.trackSpan`, only when
  there are at least three tracks); `_scrollCanAddToTrack` checks track
  overlap instead of equal y positions for such items. Items with span 1 use
  the original equality test, so plain danmaku are placed exactly as before.
- Image items measure their width with the paragraph's `maxIntrinsicWidth`
  (laid out once with infinite width) instead of a `TextPainter`.

Special (advanced) danmaku ignore segments.

## Lifecycle and small players

- `DanmakuScreen.didChangeAppLifecycleState`: the original paused the screen
  when the app went to the background and never resumed it, so after the first
  trip to the background every new danmaku was dropped (`addDanmaku` returns
  while not running). It now resumes on `resumed` if the background caused the
  pause; a manual `pause()` is left alone.
- At least one track when one line fits and `area > 0`: a short player
  (portrait, ~190 px) with a small display area used to get zero tracks and
  show nothing.
- Tests: `test/danmaku_screen_test.dart`.

## Emote size

- `DanmakuOption.emoteScale` (default 1): inline emote height is
  `fontSize * 1.15 * emoteScale`, a scrolling sticker takes `round(2 * emoteScale)`
  tracks. A scrolling item whose paragraph is taller than one track takes as many
  tracks as it needs (`trackSpan`); top/bottom items keep emotes within one line.
- `DanmakuItem.emoteFactor` keeps the item's emote height relative to the font size,
  so paragraphs rebuilt after a font size change keep the same proportions.
- `Utils.generateParagraph` / `generateStrokeParagraph` take an optional
  `emoteHeight`.
