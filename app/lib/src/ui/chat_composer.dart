import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'command_suggestion_panel.dart';

/// Shared message composer: a rounded input box with an expand button pinned
/// to its top-right, and a button row below it — '/' slash commands, '$'
/// skill commands, an optional image/attachment button, and the send button
/// at the right end.
///
/// Enter sends from the compact box; the expand button opens a full-screen
/// editor (same text) where Enter inserts a newline instead and sending is
/// done via the send button.
///
/// The composer owns its TextEditingController/FocusNode. [onSend] receives
/// the raw text and returns true when the message was accepted — the composer
/// then clears the text, and an open expanded editor closes itself. Returning
/// false preserves the draft (e.g. after a failed send).
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.app,
    required this.hintText,
    required this.onSend,
    this.onPickAttachment,
    this.busy = false,
    this.header,
  });

  final AppController app;
  final String hintText;
  final Future<bool> Function(String text) onSend;

  /// When non-null the image button is shown; the host owns picking/uploading.
  final VoidCallback? onPickAttachment;

  /// Externally busy (e.g. an upload in flight) — disables send/attachment.
  final bool busy;

  /// Staged-attachment chips etc., shown between the suggestion panel and the
  /// input box.
  final Widget? header;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// Busy state mirrored for the expanded editor, which lives on a separate
  /// route and cannot rebuild when this state changes.
  final _busyListenable = ValueNotifier<bool>(false);
  bool _sending = false;

  /// Latest header (attachment chips) mirrored the same way, so chips added
  /// from the expanded editor (or upload progress ticking while it is open)
  /// show up there too.
  final _headerListenable = ValueNotifier<Widget?>(null);

  bool get _busy => widget.busy || _sending;

  @override
  void initState() {
    super.initState();
    _syncBusy();
    _headerListenable.value = widget.header;
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // These mirrors feed the expanded editor's ValueListenableBuilders, and
    // didUpdateWidget runs mid-build — notifying listeners here trips
    // "markNeedsBuild called during build", so defer to after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _busyListenable.value = _busy;
      _headerListenable.value = widget.header;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _busyListenable.dispose();
    _headerListenable.dispose();
    super.dispose();
  }

  void _syncBusy() => _busyListenable.value = _busy;

  Future<bool> _send() async {
    if (_busy) return false;
    setState(() => _sending = true);
    _syncBusy();
    try {
      final accepted = await widget.onSend(_controller.text);
      if (accepted && mounted) _controller.clear();
      return accepted;
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _syncBusy();
      }
    }
  }

  /// Inserts a '/' or '$' trigger at the cursor (appended at the end when
  /// there is no selection), keeping it whitespace-delimited so the
  /// suggestion panel picks it up.
  static void _insertTrigger(
    TextEditingController controller,
    FocusNode focusNode,
    String symbol,
  ) {
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final needsLeadingSpace =
        start > 0 && !RegExp(r'\s').hasMatch(value.text[start - 1]);
    final insert = '${needsLeadingSpace ? ' ' : ''}$symbol';
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    focusNode.requestFocus();
  }

  void _openExpanded() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ExpandedComposerPage(
          app: widget.app,
          controller: _controller,
          hintText: widget.hintText,
          busyListenable: _busyListenable,
          headerListenable: _headerListenable,
          onSend: _send,
          onPickAttachment: widget.onPickAttachment,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final header = widget.header;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CommandSuggestionPanel(
              app: widget.app,
              controller: _controller,
              focusNode: _focusNode,
            ),
            if (header != null) ...[header, const SizedBox(height: 6)],
            _ComposerInputBox(
              controller: _controller,
              focusNode: _focusNode,
              hintText: widget.hintText,
              onSubmitted: (_) => _send(),
              onExpand: _openExpanded,
            ),
            const SizedBox(height: 4),
            _ComposerButtonRow(
              busy: _busy,
              showAttachment: widget.onPickAttachment != null,
              onSlash: () => _insertTrigger(_controller, _focusNode, '/'),
              onSkill: () => _insertTrigger(_controller, _focusNode, r'$'),
              onAttachment: widget.onPickAttachment,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }
}

/// Rounded input box with the expand button pinned to its top-right.
class _ComposerInputBox extends StatelessWidget {
  const _ComposerInputBox({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onSubmitted,
    required this.onExpand,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.send,
              onSubmitted: onSubmitted,
              decoration: InputDecoration(
                hintText: hintText,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: IconButton(
              tooltip: '放大编辑',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(backgroundColor: Colors.transparent),
              onPressed: onExpand,
              icon: const Icon(Icons.open_in_full),
            ),
          ),
        ],
      ),
    );
  }
}

/// The row under the input box: '/' and '$' trigger buttons, the optional
/// attachment button, and the send button pinned to the right.
class _ComposerButtonRow extends StatelessWidget {
  const _ComposerButtonRow({
    required this.busy,
    required this.showAttachment,
    required this.onSlash,
    required this.onSkill,
    required this.onAttachment,
    required this.onSend,
  });

  final bool busy;
  final bool showAttachment;
  final VoidCallback onSlash;
  final VoidCallback onSkill;
  final VoidCallback? onAttachment;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TriggerButton(
          symbol: '/',
          tooltip: '斜杠命令',
          onPressed: busy ? null : onSlash,
        ),
        _TriggerButton(
          symbol: r'$',
          tooltip: '技能命令',
          onPressed: busy ? null : onSkill,
        ),
        if (showAttachment)
          IconButton(
            tooltip: '添加附件',
            onPressed: busy ? null : onAttachment,
            icon: const Icon(Icons.image_outlined),
          ),
        const Spacer(),
        IconButton(
          tooltip: '发送',
          style: IconButton.styleFrom(backgroundColor: Colors.transparent),
          onPressed: busy ? null : onSend,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }
}

/// A text-glyph icon button ('/' or '$') — Material has no glyph for these.
class _TriggerButton extends StatelessWidget {
  const _TriggerButton({
    required this.symbol,
    required this.tooltip,
    required this.onPressed,
  });

  final String symbol;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Text(
        symbol,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: onPressed == null
              ? theme.disabledColor
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Full-screen editor opened from the expand button. Shares the composer's
/// controller so text flows back when collapsed. Enter inserts a newline
/// here (the compact box's Enter sends); sending is done via the button row.
class _ExpandedComposerPage extends StatefulWidget {
  const _ExpandedComposerPage({
    required this.app,
    required this.controller,
    required this.hintText,
    required this.busyListenable,
    required this.headerListenable,
    required this.onSend,
    required this.onPickAttachment,
  });

  final AppController app;
  final TextEditingController controller;
  final String hintText;
  final ValueListenable<bool> busyListenable;

  /// The compact composer's attachment chips, mirrored so staging/upload
  /// feedback is visible while the editor is open (chips are rendered here,
  /// owned by the host page either way).
  final ValueListenable<Widget?> headerListenable;

  /// Returns true when the message was accepted — the editor then closes
  /// itself.
  final Future<bool> Function() onSend;
  final VoidCallback? onPickAttachment;

  @override
  State<_ExpandedComposerPage> createState() => _ExpandedComposerPageState();
}

class _ExpandedComposerPageState extends State<_ExpandedComposerPage> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// On accepted send the editor closes. It is not necessarily the top route
  /// — the sessions page pushes the new conversation DURING onSend, leaving
  /// this editor underneath it — so pop when current, otherwise lift it out
  /// of the middle of the stack.
  Future<void> _sendAndClose() async {
    final accepted = await widget.onSend();
    if (!accepted || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Spacer(),
                  IconButton(
                    tooltip: '收起',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_fullscreen),
                  ),
                ],
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              CommandSuggestionPanel(
                app: widget.app,
                controller: widget.controller,
                focusNode: _focusNode,
              ),
              ValueListenableBuilder<Widget?>(
                valueListenable: widget.headerListenable,
                builder: (context, header, _) {
                  if (header == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: header,
                    ),
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: widget.busyListenable,
                builder: (context, busy, _) => _ComposerButtonRow(
                  busy: busy,
                  showAttachment: widget.onPickAttachment != null,
                  onSlash: () => _ChatComposerState._insertTrigger(
                    widget.controller,
                    _focusNode,
                    '/',
                  ),
                  onSkill: () => _ChatComposerState._insertTrigger(
                    widget.controller,
                    _focusNode,
                    r'$',
                  ),
                  onAttachment: widget.onPickAttachment,
                  onSend: _sendAndClose,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
