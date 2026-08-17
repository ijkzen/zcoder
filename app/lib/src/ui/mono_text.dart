import 'package:flutter/material.dart';

/// Monospace block for verbatim tool input/output and other detail — shared
/// by the tool-call detail dialog (conversation page) and the permission
/// sheet's command preview.
class MonoText extends StatelessWidget {
  final String text;
  const MonoText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: scheme.onSurfaceVariant,
          height: 1.45,
        ),
      ),
    );
  }
}

/// Small label above a [MonoText] detail block ("输入" / "命令" / …).
class DetailLabel extends StatelessWidget {
  final String text;
  const DetailLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
