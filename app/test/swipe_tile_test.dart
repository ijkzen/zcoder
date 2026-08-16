import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hit-test verification of the two-layer swipe tile: the card translates
/// left while the action strip translates in from the right, staying flush
/// with the card's right edge. Both layers stay within the tile's own size,
/// so hit-testing works at every drag offset (unlike a single wide strip,
/// which RenderBox.hitTest clips at its own bounds).
void main() {
  testWidgets('action buttons tappable after swipe open, hidden when closed',
      (tester) async {
    int renameTaps = 0;
    int archiveTaps = 0;
    int closeTaps = 0;
    const reveal = 152.0;
    bool open = false;
    double drag = 0; // 0 (closed) … -reveal (open)

    Widget buildTile() {
      const tileWidth = 700.0;
      final cardOffset = drag; // 0 … -152
      return ClipRect(
        child: SizedBox(
          width: tileWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => drag = (drag + d.delta.dx)
                .clamp(-reveal, 0.0)
                .toDouble(),
            onHorizontalDragEnd: (_) => open = drag < -reveal / 2,
            onTap: open ? () => closeTaps++ : null,
            child: Stack(
              children: [
                // Action strip: right-aligned, slides in from beyond the
                // right edge as the card slides left.
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: reveal + cardOffset),
                    duration: const Duration(milliseconds: 200),
                    builder: (context, actionOffset, child) =>
                        Transform.translate(
                      offset: Offset(actionOffset, 0),
                      child: child,
                    ),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _btn(label: '重命名', onTap: () => renameTaps++),
                          const SizedBox(width: 8),
                          _btn(label: '归档', onTap: () => archiveTaps++),
                        ],
                      ),
                    ),
                  ),
                ),
                // Card on top.
                TweenAnimationBuilder<double>(
                  tween: Tween(end: cardOffset),
                  duration: const Duration(milliseconds: 200),
                  builder: (context, offset, child) => Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                  child: AbsorbPointer(
                    absorbing: open,
                    child: const Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(title: Text('hello')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget host() => MaterialApp(
          home: Scaffold(
              body: ListView(children: [Builder(builder: (_) => buildTile())])),
        );
    await tester.pumpWidget(host());

    // Closed: buttons are beyond the clip — not hittable, not visible.
    expect(find.text('归档').hitTestable().evaluate(), isEmpty);

    // Drag open and settle.
    await tester.drag(find.text('hello'), const Offset(-200, 0));
    await tester.pumpAndSettle();
    drag = -reveal;
    open = true;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // Open: buttons hittable and tapping fires their callbacks.
    debugPrint('hittable archive: ${find.text('归档').hitTestable().evaluate().length}');
    expect(find.text('归档').hitTestable().evaluate(), isNotEmpty);
    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(archiveTaps, 1, reason: 'archive InkWell onTap should fire');

    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(renameTaps, 1, reason: 'rename InkWell onTap should fire');

    // Tapping the card while open triggers the tile's close handler (the
    // card's own ListTile tap is absorbed).
    await tester.tap(find.text('hello'));
    await tester.pumpAndSettle();
    expect(closeTaps, 1, reason: 'tile close tap should fire while open');
  });
}

Widget _btn({required String label, required VoidCallback onTap}) {
  return SizedBox(
    width: 72,
    child: Material(
      color: Colors.red,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.archive_outlined, size: 20),
            const SizedBox(height: 2),
            Text(label),
          ],
        ),
      ),
    ),
  );
}
