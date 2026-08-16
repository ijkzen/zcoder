import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/topics/topic_models.dart';

/// Bottom-sheet picker for a session's model + thought level, as a three-level
/// cascade: Provider → Model → thought level (the levels a model supports).
/// Used both to switch the open conversation's config and to pick the
/// model/thought level when creating a new session.
class ModelConfigSheet extends StatefulWidget {
  final SessionModelConfig config;
  final Future<void> Function(
    String provider,
    String model,
    String? thoughtLevel,
  )
  onApply;

  /// Extra subtitle shown under the sheet title (e.g. "仅用于本次创建").
  final String? subtitle;

  /// Whether applying a selection closes the sheet right away. The new-session
  /// picker keeps it open so the user can adjust, then confirms via 完成.
  final bool autoClose;

  /// Collaboration-mode chips (build/edit/plan/yolo). Only shown when
  /// [onModeChanged] is provided (the open-conversation switcher).
  final List<String> modeOptions;
  final String? currentMode;
  final Future<void> Function(String mode)? onModeChanged;

  /// When true every selection is disabled (e.g. the agent is running —
  /// session-level rewrites wait until it stops). The sheet stays open for
  /// browsing, with [lockedReason] shown as a banner.
  final bool locked;
  final String? lockedReason;

  const ModelConfigSheet({
    super.key,
    required this.config,
    required this.onApply,
    this.subtitle,
    this.autoClose = true,
    this.modeOptions = const ['build', 'edit', 'plan', 'yolo'],
    this.currentMode,
    this.onModeChanged,
    this.locked = false,
    this.lockedReason,
  });

  @override
  State<ModelConfigSheet> createState() => _ModelConfigSheetState();
}

/// One provider bucket in the cascade: id + display name + its models.
class _ProviderGroup {
  final String providerId;
  final String label;
  final List<ModelOption> models;

  _ProviderGroup(this.providerId, this.label, this.models);
}

class _ModelConfigSheetState extends State<ModelConfigSheet> {
  static const _levels = ['Provider', 'Model', 'Thought'];

  int _level = 0;
  String? _provider;
  ModelOption? _model;
  String? _thought;
  bool _busy = false;

  /// Locally selected collaboration mode (optimistic: the chip highlights
  /// immediately; the caller persists via onModeChanged).
  String? _mode;

  List<_ProviderGroup> get _providers {
    final byProvider = <String, List<ModelOption>>{};
    for (final m in widget.config.availableModels) {
      byProvider.putIfAbsent(m.provider, () => []).add(m);
    }
    return [
      for (final entry in byProvider.entries)
        _ProviderGroup(
          entry.key,
          entry.value.firstOrNull?.providerLabel?.isNotEmpty == true
              ? entry.value.first.providerLabel!
              : entry.key,
          entry.value,
        ),
    ];
  }

  List<ModelOption> get _models => widget.config.availableModels
      .where((m) => m.provider == _provider)
      .toList();

  List<ThoughtLevelOption> get _thoughts {
    final fromModel = _model?.reasoningLevels ?? const <ThoughtLevelOption>[];
    if (fromModel.isNotEmpty) return fromModel;
    return widget.config.availableThoughtLevels;
  }

  void _selectProvider(String providerId) {
    setState(() {
      _provider = providerId;
      _model = null;
      _thought = null;
      _level = 1;
    });
  }

  void _selectModel(ModelOption model) {
    setState(() {
      _model = model;
      _thought = null;
    });
    if (model.reasoningLevels.isEmpty &&
        widget.config.availableThoughtLevels.isEmpty) {
      _apply(model.provider, model.model, null);
    } else {
      setState(() => _level = 2);
    }
  }

  void _selectThought(String level) {
    final model = _model;
    if (model == null) return;
    _thought = level;
    _apply(model.provider, model.model, level);
  }

  Future<void> _apply(String provider, String model, String? thought) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onApply(provider, model, thought);
      if (mounted && widget.autoClose) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() {
    if (_level <= 0) return;
    setState(() => _level -= 1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currentProvider = _provider ?? widget.config.provider;
    final currentModel =
        _model?.model ?? (_provider == null ? widget.config.model : null);
    final currentThought = _thought ?? widget.config.thoughtLevel;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (_level > 0)
                  IconButton(
                    tooltip: '返回',
                    onPressed: _back,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_back),
                  ),
                Icon(Icons.tune, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text('模型与思考等级', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            if (widget.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (widget.locked) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: scheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.lockedReason ?? '当前不可切换',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            // Breadcrumb of the current selection path.
            Text(
              [
                'Provider：${_providerLabel(currentProvider) ?? '未选择'}',
                '模型：${currentModel ?? '未选择'}',
                '思考：${currentThought ?? '未选择'}',
              ].join('  ›  '),
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (widget.onModeChanged != null) ...[
              const SizedBox(height: 10),
              _modeChips(
                label: '协作模式',
                options: widget.modeOptions,
                current: widget.currentMode,
                onChanged: widget.onModeChanged,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '第 ${_level + 1} 级 · 选择${_levels[_level]}',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.tertiary),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: math.min(360.0, MediaQuery.sizeOf(context).height * 0.42),
              child: switch (_level) {
                0 => _providerList(scheme),
                1 => _modelList(scheme),
                _ => _thoughtList(scheme),
              },
            ),
            if (!widget.autoClose) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _providerLabel(String? providerId) {
    if (providerId == null) return null;
    for (final p in _providers) {
      if (p.providerId == providerId) return p.label;
    }
    return providerId;
  }

  /// One chip row (collaboration mode). Applies immediately (optimistic
  /// selection); failures surface via the caller's snackbar.
  Widget _modeChips({
    required String label,
    required List<String> options,
    required String? current,
    Future<void> Function(String mode)? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final handler = onChanged;
    final selectedMode = _mode ?? current;
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final mode in options)
                ChoiceChip(
                  label: Text(mode),
                  selected: mode == selectedMode,
                  visualDensity: VisualDensity.compact,
                  onSelected:
                      widget.locked ||
                          _busy ||
                          mode == selectedMode ||
                          handler == null
                      ? null
                      : (selected) async {
                          setState(() {
                            _busy = true;
                            _mode = mode;
                          });
                          try {
                            await handler(mode);
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _providerList(ColorScheme scheme) {
    final current = _provider ?? widget.config.provider;
    return ListView.builder(
      itemCount: _providers.length,
      itemBuilder: (context, i) {
        final group = _providers[i];
        final selected = group.providerId == current;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            group.label,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          subtitle: Text(
            '${group.models.length} 个模型',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          trailing: selected
              ? Icon(Icons.check_circle, size: 20, color: scheme.primary)
              : const Icon(Icons.chevron_right),
          onTap: widget.locked || _busy
              ? null
              : () => _selectProvider(group.providerId),
        );
      },
    );
  }

  Widget _modelList(ColorScheme scheme) {
    final current = _model?.model;
    return ListView.builder(
      itemCount: _models.length,
      itemBuilder: (context, i) {
        final model = _models[i];
        final selected = model.model == current;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            model.label,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          subtitle: Text(
            model.contextWindow != null
                ? '上下文 ${model.contextWindow!} tokens'
                : (model.providerLabel ?? ''),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          trailing: selected
              ? Icon(Icons.check_circle, size: 20, color: scheme.primary)
              : const Icon(Icons.chevron_right),
          onTap: widget.locked || _busy ? null : () => _selectModel(model),
        );
      },
    );
  }

  Widget _thoughtList(ColorScheme scheme) {
    final thoughts = _thoughts;
    final current = _thought ?? widget.config.thoughtLevel;
    if (thoughts.isEmpty) {
      return Center(
        child: Text(
          '该模型不支持思考等级',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      itemCount: thoughts.length,
      itemBuilder: (context, i) {
        final level = thoughts[i];
        final selected = level.value == current;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            level.label,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          trailing: selected
              ? Icon(Icons.check_circle, size: 20, color: scheme.primary)
              : null,
          onTap: widget.locked || _busy
              ? null
              : () => _selectThought(level.value),
        );
      },
    );
  }
}
