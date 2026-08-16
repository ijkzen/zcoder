import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/ui/project_avatar.dart';

/// Project avatars: colored circle + white initial. The color must be stable
/// per label (no reshuffling between rebuilds) and every palette entry must
/// keep white text readable.
void main() {
  test('letter is the first character, uppercased', () {
    expect(projectAvatarLetter('zcoder'), 'Z');
    expect(projectAvatarLetter(' my-project '), 'M');
    expect(projectAvatarLetter('中文项目'), '中');
    expect(projectAvatarLetter(''), '?');
    expect(projectAvatarLetter('   '), '?');
  });

  test('color is deterministic per label', () {
    expect(projectAvatarColor('zcoder'), projectAvatarColor('zcoder'));
    expect(projectAvatarColor('/Users/ijkzen/Projects/zcoder'),
        projectAvatarColor('/Users/ijkzen/Projects/zcoder'));
  });

  test('different labels spread across the palette', () {
    final colors = {
      for (final label in [
        'alpha',
        'beta',
        'gamma',
        'delta',
        'epsilon',
        'zeta',
        'eta',
        'theta',
      ])
        projectAvatarColor(label),
    };
    // Not strictly guaranteed, but 8 distinct labels collapsing to fewer
    // than 3 colors would mean the hash is broken.
    expect(colors.length, greaterThanOrEqualTo(3));
  });

  test('every palette color contrasts with white text (>= 4.5)', () {
    double luminanceOf(Color c) => c.computeLuminance();
    double contrastWithWhite(Color c) => 1.05 / (luminanceOf(c) + 0.05);
    for (final color in palette) {
      expect(
        contrastWithWhite(color),
        greaterThanOrEqualTo(4.5),
        reason: '$color is too light for white text',
      );
    }
  });
}
