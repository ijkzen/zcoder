/// Bottom sheet that resolves pending interactions of every kind:
/// AskUserQuestion question pages, permission (approval) options, and
/// free-text elicitations. Answers are passed to [RequestSheet.onResolve],
/// which the host translates into a `resolveInteraction` command.
library;

import 'package:flutter/material.dart';

import '../protocol/topics/topic_models.dart';

/// One "page" of the horizontal request list.
sealed class _SheetPage {
  final PendingRequest request;
  const _SheetPage(this.request);
}

/// An AskUserQuestion question (one page per question).
class _QuestionPage extends _SheetPage {
  final InteractionQuestion question;
  const _QuestionPage(super.request, this.question);
}

/// An allow/deny permission: show the tool's reason and its options.
class _PermissionPage extends _SheetPage {
  const _PermissionPage(super.request);
}

/// A free-text (or ExitPlanMode plan) elicitation with optional simple
/// options.
class _FreeTextPage extends _SheetPage {
  const _FreeTextPage(super.request);
}

class RequestSheet extends StatefulWidget {
  final List<PendingRequest> requests;
  final Future<void> Function(PendingRequest request, Map<String, Object?> answer)
      onResolve;

  const RequestSheet({super.key, required this.requests, required this.onResolve});

  @override
  State<RequestSheet> createState() => _RequestSheetState();
}

class _RequestSheetState extends State<RequestSheet> {
  late final PageController _pageController;
  int _page = 0;
  bool _submitting = false;

  /// Flattens every interaction into one horizontal list: questions get one
  /// page each, permissions and free-text elicitations one page per request.
  late final List<_SheetPage> _pages = [
    for (final request in widget.requests)
      if (request.hasQuestions)
        for (final question in request.questions)
          _QuestionPage(request, question)
      else if (request.isFreeTextInput || request.isExitPlanMode)
        _FreeTextPage(request)
      else
        _PermissionPage(request),
  ];

  /// question text -> chosen option values (value, else label).
  final Map<String, Set<String>> _selections = {};
  final Map<String, TextEditingController> _customControllers = {};

  /// permission optionId -> selected (single choice per permission request).
  final Map<String, String> _permissionSelections = {};

  /// free-text page prompt -> typed text.
  final Map<String, TextEditingController> _freeTextControllers = {};

  /// simple (optionId/label) option chosen on a free-text page.
  final Map<String, String> _simpleOptionSelections = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _customControllers.values) {
      c.dispose();
    }
    for (final c in _freeTextControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _customController(String question) =>
      _customControllers.putIfAbsent(question, TextEditingController.new);

  TextEditingController _freeTextController(String key) =>
      _freeTextControllers.putIfAbsent(key, TextEditingController.new);

  static String _optionIdentity(InteractionQuestionOption option) =>
      option.value.trim().isEmpty ? option.label : option.value;

  bool get _currentAnswered {
    final page = _pages[_page];
    switch (page) {
      case _QuestionPage(:final question):
        return (_selections[question.question]?.isNotEmpty ?? false) ||
            _customController(question.question).text.trim().isNotEmpty;
      case _PermissionPage(:final request):
        return _permissionSelections[request.requestId] != null;
      case _FreeTextPage(:final request):
        final simple = _simpleOptionSelections[request.requestId];
        if (simple != null) return true;
        return request.isFreeTextInput &&
            _freeTextController(request.requestId).text.trim().isNotEmpty;
    }
  }

  void _toggle(InteractionQuestion question, InteractionQuestionOption option) {
    final identity = _optionIdentity(option);
    setState(() {
      final selected = _selections.putIfAbsent(question.question, () => {});
      if (question.multiSelect) {
        if (!selected.remove(identity)) selected.add(identity);
      } else {
        selected
          ..clear()
          ..add(identity);
      }
    });
    // Single-choice questions are "answered" on tap: jump to the next page.
    if (!question.multiSelect && _page < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void _goNext() {
    if (_page >= _pages.length - 1) return;
    _pageController.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// The answer for one page, or null when the user answered nothing on it
  /// (unanswered pages are left pending — the runtime auto-resolves them
  /// after its deadline).
  Map<String, Object?>? _answerFor(_SheetPage page) {
    switch (page) {
      case _QuestionPage(:final request):
        final selections = <String, List<String>>{
          for (final q in request.questions)
            q.question: [
              ...?_selections[q.question],
              if (_customController(q.question).text.trim().isNotEmpty)
                _customController(q.question).text.trim(),
            ],
        };
        if (selections.values.every((v) => v.isEmpty)) return null;
        return {
          'action': 'accept',
          'content': buildQuestionAnswerContent(request.questions, selections),
        };
      case _PermissionPage(:final request):
        final optionId = _permissionSelections[request.requestId];
        if (optionId == null) return null;
        return {'optionId': optionId};
      case _FreeTextPage(:final request):
        final simple = _simpleOptionSelections[request.requestId];
        if (simple != null) return {'optionId': simple};
        final text = _freeTextController(request.requestId).text.trim();
        if (text.isEmpty) return null;
        return {'freeText': text};
    }
  }

  /// Resolution for a user-initiated cancel. Elicitations accept
  /// `action: cancel`; permissions have no action — fall back to the deny
  /// option when one exists, otherwise leave the request pending (the
  /// runtime auto-resolves after its deadline).
  Map<String, Object?>? _cancelAnswerFor(_SheetPage page) {
    switch (page) {
      case _QuestionPage():
      case _FreeTextPage():
        return {'action': 'cancel'};
      case _PermissionPage(:final request):
        final deny = request.options
            .where((o) => o.kind == 'deny')
            .firstOrNull;
        if (deny != null) return {'optionId': deny.optionId};
        return null;
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      // Resolve every page with the answers accumulated so far (one request
      // may own several question pages; resolve it once).
      final resolved = <String>{};
      for (final page in _pages) {
        if (resolved.contains(page.request.requestId)) continue;
        final answer = _answerFor(page);
        if (answer == null) continue;
        resolved.add(page.request.requestId);
        await widget.onResolve(page.request, answer);
      }
      // Close the panel once the answers are away; the next readSession poll
      // drops the resolved requests from the entries row.
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancel() async {
    final page = _pages[_page];
    final answer = _cancelAnswerFor(page);
    if (answer == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.onResolve(page.request, answer);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allPermissions = widget.requests.every((r) => !r.isElicitation);
    final allQuestions = widget.requests.every(
        (r) => r.hasQuestions || r.isFreeTextInput || r.isExitPlanMode);
    final title = allPermissions
        ? '需要批准'
        : allQuestions
            ? '需要你的回答'
            : '需要处理';

    return SizedBox(
      // No local background: the sheet's own default background must stay
      // uniform across the drag handle, header and page content (a local
      // color here shows up as a mismatched band against the sheet default).
      height: MediaQuery.sizeOf(context).height * 0.66,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Icon(
                    allPermissions
                        ? Icons.verified_user_outlined
                        : Icons.quiz_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  // Question position dots.
                  if (_pages.length > 1)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < _pages.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            width: i == _page ? 14 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _page
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final page = _pages[i];
                  return switch (page) {
                    _QuestionPage() => _buildQuestionPage(scheme, page),
                    _PermissionPage() => _buildPermissionPage(scheme, page),
                    _FreeTextPage() => _buildFreeTextPage(scheme, page),
                  };
                },
              ),
            ),
            // Bottom actions.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (_page == _pages.length - 1) ...[
                    FilledButton(
                      onPressed: _submitting || !_currentAnswered
                          ? null
                          : _submit,
                      child: const Text('提交'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _submitting ? null : _cancel,
                      child: const Text('取消'),
                    ),
                  ] else
                    FilledButton(
                      onPressed: _currentAnswered ? _goNext : null,
                      child: const Text('下一题'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestionPage(ColorScheme scheme, _QuestionPage page) {
    final q = page.question;
    final selected = _selections[q.question] ?? const <String>{};
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (q.header.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                q.header,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.tertiary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  q.question,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurface),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                q.multiSelect ? '可多选' : '单选',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final option in q.options)
            _QuestionOptionTile(
              option: option,
              multiSelect: q.multiSelect,
              selected: selected.contains(_optionIdentity(option)),
              onTap: _submitting ? null : () => _toggle(q, option),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _customController(q.question),
              enabled: !_submitting,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: q.multiSelect ? '其他回答（可多选后补充）' : '其他回答…',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionPage(ColorScheme scheme, _PermissionPage page) {
    final request = page.request;
    final selectedId = _permissionSelections[request.requestId];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  request.prompt,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurface),
                ),
              ),
              if (request.riskLevel.isNotEmpty) ...[
                const SizedBox(width: 8),
                _RiskChip(level: request.riskLevel),
              ],
            ],
          ),
          if (request.toolName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                request.toolName,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          const SizedBox(height: 8),
          for (final option in request.options)
            _PermissionOptionTile(
              option: option,
              selected: option.optionId == selectedId,
              onTap: _submitting
                  ? null
                  : () => setState(() {
                        _permissionSelections[request.requestId] =
                            option.optionId;
                      }),
            ),
          if (request.options.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '（无可用选项）',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFreeTextPage(ColorScheme scheme, _FreeTextPage page) {
    final request = page.request;
    final selectedSimple = _simpleOptionSelections[request.requestId];
    final simpleOptions = request.input['options'] is List
        ? (request.input['options'] as List)
            .whereType<Map<String, Object?>>()
            .map((o) => (
                  o['optionId']?.toString() ?? '',
                  o['label']?.toString() ?? '',
                ))
            .toList()
        : const <(String, String)>[];
    final prompt = request.isExitPlanMode
        ? (request.input['plan']?.toString().isNotEmpty == true
            ? request.input['plan'].toString()
            : request.prompt)
        : (request.input['prompt']?.toString().isNotEmpty == true
            ? request.input['prompt'].toString()
            : request.prompt);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            prompt,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurface),
          ),
          if (simpleOptions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (optionId, label) in simpleOptions)
                  ChoiceChip(
                    label: Text(label.isEmpty ? optionId : label),
                    selected: selectedSimple == optionId,
                    onSelected: _submitting
                        ? null
                        : (_) => setState(() {
                              _simpleOptionSelections[request.requestId] =
                                  optionId;
                            }),
                  ),
              ],
            ),
          ],
          if (request.isFreeTextInput) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _freeTextController(request.requestId),
                enabled: !_submitting,
                onChanged: (_) => setState(() {}),
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: '输入你的回答…',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RiskChip extends StatelessWidget {
  final String level; // low | medium | high | critical
  const _RiskChip({required this.level});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color color, String label) = switch (level) {
      'low' => (scheme.primary, '低风险'),
      'medium' => (scheme.tertiary, '中风险'),
      'high' => (Colors.orange.shade700, '高风险'),
      'critical' => (scheme.error, '严重风险'),
      _ => (scheme.outline, level),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// One selectable permission option row (allow once / always / deny / custom).
class _PermissionOptionTile extends StatelessWidget {
  final PendingRequestOption option;
  final bool selected;
  final VoidCallback? onTap;

  const _PermissionOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = option.name.isNotEmpty
        ? option.name
        : (PendingRequest.optionKindLabel(option.kind).isNotEmpty
            ? PendingRequest.optionKindLabel(option.kind)
            : option.optionId);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: selected ? scheme.primary : scheme.onSurface,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                  ),
                  if (option.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        option.description,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One selectable option row: a radio/checkbox indicator, the option label,
/// and the description underneath.
class _QuestionOptionTile extends StatelessWidget {
  final InteractionQuestionOption option;
  final bool multiSelect;
  final bool selected;
  final VoidCallback? onTap;

  const _QuestionOptionTile({
    required this.option,
    required this.multiSelect,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              multiSelect
                  ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
                  : (selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.label.isEmpty ? '（无标签）' : option.label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: selected ? scheme.primary : scheme.onSurface,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                  ),
                  if (option.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        option.description,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
