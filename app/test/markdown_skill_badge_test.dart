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

/// Parses [source] with the chat (skill + slash) badge extension set and
/// returns the names of every `slashBadge` element in document order.
List<String> slashNames(String source) {
  final doc = md.Document(extensionSet: chatBadgeExtensionSet);
  final nodes = doc.parseLines(const LineSplitter().convert(source));
  final names = <String>[];
  void walk(md.Node node) {
    if (node is md.Element) {
      if (node.tag == 'slashBadge') {
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

/// All inline element tags of [source] parsed with [chatBadgeExtensionSet].
List<String> tags(String source) {
  final doc = md.Document(extensionSet: chatBadgeExtensionSet);
  final nodes = doc.parseLines(const LineSplitter().convert(source));
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
  return tags;
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

  group('SlashInvokeSyntax', () {
    test('leading slash command', () {
      expect(
        slashNames('/flutter_project_upgrade 升级项目'),
        ['flutter_project_upgrade'],
      );
    });

    test('nested command via colon + hyphenated name', () {
      expect(
        slashNames(r'用 /zcode-guide:diagnosing-commands 排查'),
        ['zcode-guide:diagnosing-commands'],
      );
    });

    test('multiple slash commands each become a badge', () {
      expect(slashNames('/a /b 开工'), ['a', 'b']);
    });

    test('URL slash is not a command (lookbehind + autolink)', () {
      expect(
        slashNames(r'请看 https://github.com/ijkzen/zcoder'),
        isEmpty,
      );
    });

    test('path segment slash is not a command', () {
      expect(slashNames(r'打开 a/b/c 目录'), isEmpty);
    });

    test('coexists with skill badges in the chat set', () {
      final all = tags(r'$skill /cmd 一起');
      expect(all, contains('skillBadge'));
      expect(all, contains('slashBadge'));
    });

    test('inside fenced code is left as text', () {
      expect(slashNames('```bash\nrun /test\n```'), isEmpty);
    });
  });

  group('hasSlashInvoke', () {
    test(r'true for /command tokens', () {
      expect(hasSlashInvoke(r'/flutter_project_upgrade x'), isTrue);
      expect(hasSlashInvoke(r'运行 /zcode-guide:diagnosing-commands'), isTrue);
    });

    test('false for URLs, paths and plain text', () {
      expect(hasSlashInvoke(r'https://github.com/x'), isFalse);
      expect(hasSlashInvoke(r'打开 a/b/c'), isFalse);
      expect(hasSlashInvoke('plain text'), isFalse);
    });
  });
}
