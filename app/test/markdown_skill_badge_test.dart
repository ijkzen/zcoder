import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:zcode_remote/src/ui/markdown_skill_badge.dart';

/// Parses [source] with the skill badge extension set and returns the names
/// of every `skillBadge` element in document order.
List<String> badgeNames(String source) {
  final doc = md.Document(extensionSet: skillBadgeExtensionSet);
  final nodes = doc.parseLines(const LineSplitter().convert(source));
  final names = <String>[];
  void walk(md.Node node) {
    if (node is md.Element) {
      if (node.tag == 'skillBadge') {
        names.add(
          node.children
              ?.whereType<md.Text>()
              .map((t) => t.text)
              .join()
              .trim() ??
              '',
        );
      }
      for (final c in node.children ?? const <md.Node>[]) {
        walk(c);
      }
    }
  }

  for (final n in nodes) {
    walk(n);
  }
  return names;
}

void main() {
  group('SkillInvokeSyntax', () {
    test(r'leading $skill-name', () {
      expect(badgeNames(r'$skill-name 帮我总结'), ['skill-name']);
    });

    test('mid-text token (dotted name)', () {
      expect(badgeNames(r'请用 $review.docs 生成'), ['review.docs']);
    });

    test('multiple tokens each become a badge', () {
      expect(badgeNames(r'$a $b 开工'), ['a', 'b']);
    });

    test(r'$ followed by a digit is not a skill', () {
      expect(badgeNames(r'价格 $100 元'), isEmpty);
    });

    test(r'lone $ is not a skill', () {
      expect(badgeNames(r'美元 $ 符号'), isEmpty);
    });

    test('inside fenced code is left as text', () {
      expect(badgeNames('```bash\necho \$HOME\n```'), isEmpty);
    });

    test('coexists with gitHubFlavored inline syntax (bold)', () {
      final doc = md.Document(extensionSet: skillBadgeExtensionSet);
      final nodes = doc.parseLines(
        const LineSplitter().convert(r'**加粗** $skill 结束'),
      );
      final tags = <String>[];
      void walk(md.Node node) {
        if (node is md.Element) {
          tags.add(node.tag);
          for (final c in node.children ?? const <md.Node>[]) {
            walk(c);
          }
        }
      }

      for (final n in nodes) {
        walk(n);
      }
      expect(tags, contains('strong'));
      expect(tags, contains('skillBadge'));
    });
  });

  group('hasSkillInvoke', () {
    test(r'true for $name tokens', () {
      expect(hasSkillInvoke(r'$skill-name x'), isTrue);
      expect(hasSkillInvoke(r'看看 $foo.bar'), isTrue);
    });

    test('false for plain text and non-skill tokens', () {
      expect(hasSkillInvoke('plain text'), isFalse);
      expect(hasSkillInvoke(r'价格 $100 元'), isFalse);
      expect(hasSkillInvoke(r'$'), isFalse);
    });
  });
}
