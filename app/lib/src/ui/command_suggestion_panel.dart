import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../protocol/services/services.dart';

/// '/' slash-command and '$' skill suggestions for a composer text field.
///
/// Listens to [controller] itself, so the host page only drops this panel
/// above its input row — no `onChanged` wiring. While the last
/// whitespace-delimited token starts with '/' or '$', matching workspace
/// slash commands (prepareWorkspace) or enabled skills are listed; tapping
/// one replaces the token with the command name plus a trailing space and
/// returns focus to the composer.
class CommandSuggestionPanel extends StatefulWidget {
  final AppController app;
  final TextEditingController controller;
  final FocusNode focusNode;

  const CommandSuggestionPanel({
    super.key,
    required this.app,
    required this.controller,
    required this.focusNode,
  });

  @override
  State<CommandSuggestionPanel> createState() => _CommandSuggestionPanelState();
}

class _CommandSuggestionPanelState extends State<CommandSuggestionPanel> {
  List<SlashCommand>? _slashCommands;
  List<SkillEntry>? _skills;
  bool _loading = false;
  String? _activePrefix; // the '/' or '$' token currently typed

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(CommandSuggestionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  /// The last whitespace-delimited token of the composer text.
  String _currentToken(String text) {
    final lastSpace = text.lastIndexOf(RegExp(r'\s'));
    return lastSpace == -1 ? text : text.substring(lastSpace + 1);
  }

  void _onTextChanged() {
    final token = _currentToken(widget.controller.text);
    final String? prefix;
    if (token.startsWith('/')) {
      prefix = token;
      _loadPrepIfNeeded();
    } else if (token.startsWith(r'$')) {
      prefix = token;
      _loadSkillsIfNeeded();
    } else {
      prefix = null;
    }
    if (prefix != _activePrefix) {
      setState(() => _activePrefix = prefix);
    }
  }

  Future<void> _loadPrepIfNeeded() async {
    if (_slashCommands != null || _loading) return;
    _loading = true;
    final prep = await widget.app.fetchWorkspacePrep();
    _slashCommands = prep?.slashCommands ?? const [];
    _loading = false;
    if (mounted) setState(() {});
  }

  Future<void> _loadSkillsIfNeeded() async {
    if (_skills != null || _loading) return;
    _loading = true;
    _skills = await widget.app.fetchSkills();
    _loading = false;
    if (mounted) setState(() {});
  }

  void _applySuggestion(String replacement) {
    final text = widget.controller.text;
    final token = _currentToken(text);
    final prefixEnd = text.length - token.length;
    widget.controller.text = '${text.substring(0, prefixEnd)}$replacement ';
    widget.controller.selection = TextSelection.collapsed(
      offset: widget.controller.text.length,
    );
    setState(() => _activePrefix = null);
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final prefix = _activePrefix;
    if (prefix == null) return const SizedBox.shrink();    final items = <Widget>[];
    if (prefix.startsWith('/')) {
      final query = prefix.substring(1);
      for (final cmd in _slashCommands ?? const <SlashCommand>[]) {
        if (!cmd.name.startsWith(query)) continue;
        items.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.sell_outlined, size: 20),
            title: Text('/${cmd.name}'),
            subtitle: cmd.description.isEmpty
                ? null
                : Text(
                    cmd.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _applySuggestion('/${cmd.name}'),
          ),
        );
      }
    } else if (prefix.startsWith(r'$')) {
      final query = prefix.substring(1);
      for (final skill in _skills ?? const <SkillEntry>[]) {
        if (!skill.name.startsWith(query)) continue;
        items.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.auto_awesome, size: 20),
            title: Text('\$${skill.name}'),
            subtitle: skill.description == null
                ? null
                : Text(
                    skill.description!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _applySuggestion('\$${skill.name}'),
          ),
        );
      }
    }
    if (items.isEmpty && !_loading) return const SizedBox.shrink();
    // The bottom gap replaces the conditional spacer the host pages used to
    // place between the panel and the composer.
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(shrinkWrap: true, children: items),
              ),
            ),
    );
  }
}
