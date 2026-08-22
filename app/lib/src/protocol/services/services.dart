/// Layer 5 — typed wrappers for the `zcode-task` and `zcode-session`
/// service channels. Only methods with probe-verified argument shapes are
/// exposed; the full method inventory lives in
/// docs/protocol/06-service-inventory.md.
library;

import 'dart:async';

import '../rpc/channel_client.dart';

/// Every call takes a workspace target: `{workspacePath, workspaceIdentity?}`.
class WorkspaceTarget {
  final String workspacePath;
  final String? workspaceIdentity;

  const WorkspaceTarget({required this.workspacePath, this.workspaceIdentity});

  Map<String, Object?> toJson() => {
    'workspacePath': workspacePath,
    if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
  };
}

/// Shared plumbing for service wrappers: every call takes the workspace
/// target alongside the method-specific args.
abstract class WorkspaceService {
  final RpcChannel _channel;
  final WorkspaceTarget target;

  WorkspaceService(this._channel, this.target);

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> args,
  ) async {
    final raw = await _channel.call(method, {...target.toJson(), ...args});
    return raw is Map<String, Object?> ? raw : const {};
  }
}

/// `zcode-task` — the terminal-facing task facade.
class ZcodeTaskService extends WorkspaceService {
  ZcodeTaskService(super.channel, super.target);

  /// `prepareWorkspace` — the workspace's config options (provider/model/
  /// thought/collaboration/followup selects) and slash commands (builtin +
  /// custom skills/MCP).
  Future<Map<String, Object?>> prepareWorkspace() =>
      _call('prepareWorkspace', const {});

  /// Cumulative token counters for a task.
  Future<Map<String, Object?>> getTaskTokenUsage(String taskId) =>
      _call('getTaskTokenUsage', {'taskId': taskId});

  /// Renames a task (no baseRevision needed, unlike the renameSession
  /// conversation command).
  Future<Map<String, Object?>> renameTask(String taskId, String title) =>
      _call('renameTask', {'taskId': taskId, 'title': title});

  /// Archives a task — archived tasks drop out of the workspace task list.
  Future<Map<String, Object?>> archiveTask(String taskId) =>
      _call('archiveTask', {'taskId': taskId});

  Future<Map<String, Object?>> unarchiveTask(String taskId) =>
      _call('unarchiveTask', {'taskId': taskId});

  /// Permanently deletes a task (the desktop cancels it first if running).
  Future<Map<String, Object?>> deleteTask(String taskId) =>
      _call('deleteTask', {'taskId': taskId});

  /// Marks a task (un)read — drives the unread badge on the sessions list.
  /// `expectedUnreadAt` optionally guards the clear against races.
  Future<Map<String, Object?>> setTaskUnread(
    String taskId, {
    required bool unread,
    int? expectedUnreadAt,
  }) => _call('setTaskUnread', {
    'taskId': taskId,
    'unread': unread,
    'expectedUnreadAt': ?expectedUnreadAt,
  });

  /// Pins / unpins a task.
  Future<Map<String, Object?>> setTaskPinned(
    String taskId, {
    required bool pinned,
  }) => _call('setTaskPinned', {'taskId': taskId, 'pinned': pinned});
}

/// `zcode-session` — session-level reads and settings.
class ZcodeSessionService extends WorkspaceService {
  ZcodeSessionService(super.channel, super.target);

  /// Snapshot of one session: `{session:{status, …}, settings:{model,
  /// thoughtLevel}, runtime:{contextUsage}, projection:{pendingPermissions},
  /// messages?}`.
  Future<Map<String, Object?>> readSession(
    String sessionId, {
    int? messageLimit,
    int? afterSeq,
  }) => _call('readSession', {
    'sessionId': sessionId,
    'messageLimit': ?messageLimit,
    'afterSeq': ?afterSeq,
  });

  /// Switches the session's model (and optionally thought level) directly on
  /// the runtime — no baseRevision needed, unlike the switchModelConfig
  /// conversation command. `model` must travel as a `{providerId, modelId}`
  /// ref object: the host resolves it against its provider registry as-is
  /// and never parses a "provider/model" string on this channel.
  Future<Map<String, Object?>> setModel(
    String sessionId, {
    required String provider,
    required String model,
    String? thoughtLevel,
  }) => _call('setModel', {
    'sessionId': sessionId,
    'model': {'providerId': provider, 'modelId': model},
    'thoughtLevel': ?thoughtLevel,
  });

  /// Switches the session's thought level (reasoning effort).
  Future<Map<String, Object?>> setThoughtLevel(
    String sessionId,
    String thoughtLevel,
  ) => _call('setThoughtLevel', {
    'sessionId': sessionId,
    'thoughtLevel': thoughtLevel,
  });

  /// The workspace's model registry and default thought level.
  Future<Map<String, Object?>> readWorkspaceState() =>
      _call('readWorkspaceState', const {});
}

/// `model-provider` channel — provider CRUD on the desktop's model registry.
class ModelProviderService {
  final RpcChannel _channel;
  ModelProviderService(this._channel);

  Future<List<Map<String, Object?>>> getAll() async {
    final raw = await _channel.call('getAll');
    if (raw is! List) return const [];
    return [
      for (final item in raw.whereType<Map>()) item.cast<String, Object?>(),
    ];
  }

  /// The host's cached registry snapshot — unlike [getAll] it skips the OAuth
  /// preset sync, so it is cheap to call from pickers. Still reflects
  /// provider deletions (the host refreshes this snapshot on every change).
  Future<List<Map<String, Object?>>> getAllCached() async {
    final raw = await _channel.call('getAllCached');
    if (raw is! List) return const [];
    return [
      for (final item in raw.whereType<Map>()) item.cast<String, Object?>(),
    ];
  }

  Future<Object?> save(Map<String, Object?> provider) => _channel.call('save', {
    ...provider,
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
  });

  // The promise path spreads the args array into the method call, so a bare
  // id arrives as `delete(id)` on the host. Wrapping it as `[{'id': id}]`
  // made the host filter `Se.id !== [{id}]` and silently no-op.
  Future<Object?> delete(String id) => _channel.call('delete', id);
}

/// `skills` channel — enabled skills of the workspace; triggered in the
/// composer as `$name`.
class SkillsService {
  final RpcChannel _channel;
  final WorkspaceTarget target;

  SkillsService(this._channel, this.target);

  Future<List<SkillEntry>> list({String provider = 'glm'}) async {
    final raw = await _channel
        .call('list', {...target.toJson(), 'provider': provider})
        .timeout(const Duration(seconds: 20));
    final list = raw is List ? raw : (raw is Map ? raw['skills'] : null);
    if (list is! List) return const [];
    return [
      for (final item in list.whereType<Map>())
        SkillEntry.fromJson(item.cast<String, dynamic>()),
    ].where((s) => s.name.isNotEmpty).toList();
  }
}

/// One slash command from `prepareWorkspace` (builtin / custom / skill / MCP).
class SlashCommand {
  final String name;
  final String description;
  final String? inputHint;
  final String source;
  const SlashCommand({
    required this.name,
    required this.description,
    this.inputHint,
    required this.source,
  });

  factory SlashCommand.fromJson(Map<String, Object?> json) => SlashCommand(
    name: json['name']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    inputHint: json['inputHint']?.toString(),
    source: json['source']?.toString() ?? '',
  );
}

/// One config option from `prepareWorkspace` (provider/model/thought/
/// collaborationMode/followupMode selects).
class ConfigOption {
  final String id;
  final String name;
  final String category;
  final String type;
  final Object? currentValue;
  final List<ConfigOptionValue> options;
  const ConfigOption({
    required this.id,
    required this.name,
    required this.category,
    required this.type,
    this.currentValue,
    required this.options,
  });

  factory ConfigOption.fromJson(Map<String, Object?> json) => ConfigOption(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    type: json['type']?.toString() ?? '',
    currentValue: json['currentValue'],
    options: [
      for (final o in (json['options'] as List? ?? const []))
        if (o is Map) ConfigOptionValue.fromJson(o.cast<String, dynamic>()),
    ],
  );
}

class ConfigOptionValue {
  final String value;
  final String name;
  final String? description;
  final String? modelProviderName;
  const ConfigOptionValue({
    required this.value,
    required this.name,
    this.description,
    this.modelProviderName,
  });

  factory ConfigOptionValue.fromJson(Map<String, Object?> json) =>
      ConfigOptionValue(
        value: json['value']?.toString() ?? '',
        name: json['name']?.toString() ?? json['value']?.toString() ?? '',
        description: json['description']?.toString(),
        modelProviderName: json['modelProviderName']?.toString(),
      );
}

/// `prepareWorkspace` result: config options + slash commands.
class WorkspacePrep {
  final List<ConfigOption> configOptions;
  final List<SlashCommand> slashCommands;
  const WorkspacePrep({
    required this.configOptions,
    required this.slashCommands,
  });

  factory WorkspacePrep.fromJson(Map<String, Object?> json) => WorkspacePrep(
    configOptions: [
      for (final o in (json['configOptions'] as List? ?? const []))
        if (o is Map) ConfigOption.fromJson(o.cast<String, dynamic>()),
    ],
    slashCommands: [
      for (final c in (json['slashCommands'] as List? ?? const []))
        if (c is Map) SlashCommand.fromJson(c.cast<String, dynamic>()),
    ],
  );

  ConfigOption? option(String id) {
    for (final o in configOptions) {
      if (o.id == id) return o;
    }
    return null;
  }
}

/// An enabled skill from `skills.list`.
class SkillEntry {
  final String id;
  final String name;
  final String path;
  final String scope;
  final String? description;
  final String? argumentHint;
  final bool enabled;
  const SkillEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.scope,
    this.description,
    this.argumentHint,
    required this.enabled,
  });

  factory SkillEntry.fromJson(Map<String, Object?> json) => SkillEntry(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    scope: json['scope']?.toString() ?? 'workspace',
    description: json['description']?.toString(),
    argumentHint: json['argumentHint']?.toString(),
    enabled: json['enabled'] != false,
  );
}
