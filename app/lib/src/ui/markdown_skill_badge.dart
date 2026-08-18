import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Skill invocations written as `$skill-name` — the composer inserts this
/// form from the skills suggestion panel (TC-CONV-016) — render as an inline
/// badge chip instead of raw text.
///
/// The custom-rule pipeline: [SkillInvokeSyntax] parses `$name` tokens into
/// `skillBadge` elements; [SkillBadgeBuilder] (registered via
/// `MarkdownBody.builders`) turns those elements into chips.

/// Matches a `$name` token where `name` starts with a letter/underscore and
/// continues with letters/digits/`_`/`.`/`-` (skill names are kebab-case).
class SkillInvokeSyntax extends md.InlineSyntax {
  SkillInvokeSyntax()
      : super(r'\$([A-Za-z_][A-Za-z0-9_.-]*)', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final name = match.group(1);
    if (name == null || name.isEmpty) return false;
    parser.addNode(md.Element.text('skillBadge', name));
    return true;
  }
}

/// gitHubFlavored plus the skill badge rule.
final md.ExtensionSet skillBadgeExtensionSet = md.ExtensionSet(
  [...md.ExtensionSet.gitHubFlavored.blockSyntaxes],
  [
    ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
    SkillInvokeSyntax(),
  ],
);

/// Whether [text] contains a `$name` skill invocation token (same shape the
/// syntax above matches; used to decide whether the user bubble needs the
/// markdown renderer at all).
final RegExp skillInvokePattern = RegExp(r'\$[A-Za-z_][A-Za-z0-9_.-]*');

bool hasSkillInvoke(String text) => skillInvokePattern.hasMatch(text);

/// Matches a `/command` token, mirroring [SkillInvokeSyntax] for slash
/// commands. Command names follow the client's command-name shape: lowercase
/// alnum start, then lowercase alnum/`_`/`-`/`:` (e.g. `flutter_project_upgrade`,
/// `zcode-guide:diagnosing-commands`). The lookbehind keeps URLs
/// (`https://…`) and paths (`a/b`) from being read as commands.
class SlashInvokeSyntax extends md.InlineSyntax {
  SlashInvokeSyntax()
      : super(
          r'(?<![A-Za-z0-9/])/([a-z0-9][a-z0-9_:-]*)',
          startCharacter: 0x2F,
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final name = match.group(1);
    if (name == null || name.isEmpty) return false;
    parser.addNode(md.Element.text('slashBadge', name));
    return true;
  }
}

/// gitHubFlavored plus the skill badge and slash-command badge rules — the
/// set used for user chat bubbles.
final md.ExtensionSet chatBadgeExtensionSet = md.ExtensionSet(
  [...md.ExtensionSet.gitHubFlavored.blockSyntaxes],
  [
    ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
    SkillInvokeSyntax(),
    SlashInvokeSyntax(),
  ],
);

/// Whether [text] contains a `/command` invocation token (same shape the
/// syntax above matches).
final RegExp slashInvokePattern = RegExp(r'(?<![A-Za-z0-9/])/[a-z0-9][a-z0-9_:-]*');

bool hasSlashInvoke(String text) => slashInvokePattern.hasMatch(text);

/// Shared pill for a skill/command badge: icon + name chip.
Widget _badgeChip(BuildContext context, IconData icon, String name) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          name,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

/// Renders a `skillBadge` element as a small icon+name chip.
class SkillBadgeBuilder extends MarkdownElementBuilder {
  SkillBadgeBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final name =
        element.children
                ?.whereType<md.Text>()
                .map((t) => t.text)
                .join()
                .trim() ??
            '';
    if (name.isEmpty) return null;
    return _badgeChip(context, Icons.auto_awesome, name);
  }
}

/// Renders a `slashBadge` element as a small icon+name chip — slash commands
/// in user messages get the same treatment skills get (`/foo` → chip).
class SlashBadgeBuilder extends MarkdownElementBuilder {
  SlashBadgeBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final name =
        element.children
                ?.whereType<md.Text>()
                .map((t) => t.text)
                .join()
                .trim() ??
            '';
    if (name.isEmpty) return null;
    return _badgeChip(context, Icons.terminal, name);
  }
}
