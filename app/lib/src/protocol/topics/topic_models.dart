/// Domain models for workspaces, sessions, and conversation rows.
library;

import 'dart:convert';

/// Canonical session phase strings shared by the controller, notifications,
/// and UI. One map instead of scattered magic strings (Repeated Switches).
class SessionPhase {
  static const running = 'running';
  static const draft = 'draft';
  static const prewarming = 'prewarming';
  static const completedSuccess = 'completedSuccess';
  static const completedInterrupted = 'completedInterrupted';
  static const error = 'error';
  static const idle = 'idle';

  /// Chinese label for display.
  static String zh(String phase) {
    switch (phase) {
      case running:
        return '运行中';
      case draft:
        return '草稿';
      case prewarming:
        return '预热中';
      case completedSuccess:
        return '已完成';
      case completedInterrupted:
        return '已中断';
      case error:
        return '出错';
      default:
        return phase;
    }
  }

  /// True for phases that end the session's foreground work.
  static bool isTerminal(String phase) =>
      phase == completedSuccess ||
      phase == completedInterrupted ||
      phase == error;
}

// ---------- Workspace ----------

/// A selectable remote-control target. The desktop's `workspace-list-response`
/// carries a `tasks` array — each task names its workspace (via
/// `workspacePath`/`workspaceLabel`) and may carry a `taskId` to open that
/// session directly when bridging.
class Workspace {
  final String workspaceKey;
  final String workspacePath;
  final String? workspaceIdentity;
  final String workspaceLabel;
  final String workspaceKind; // "local" | "remote"
  final String connectionState; // "connected" | "disconnected" | "reconnecting"
  final String? lastConnectionError;

  // Task-shaped fields (present when parsed from the `tasks` array).
  final String? taskId;
  final String displayStatus; // idle | running | completed | error
  final String? taskTitle;
  final int? createdAt;
  final int? updatedAt;

  /// Archived tasks stay in the workspace-list payload but must not render
  /// (the desktop's web client filters on this same flag).
  final bool archived;

  /// Pinned tasks sort to the top of the task list (wire `pinned`).
  final bool pinned;

  /// Non-null when the task has unread activity (`unreadAt` millis).
  final int? unreadAt;

  const Workspace({
    required this.workspaceKey,
    required this.workspacePath,
    this.workspaceIdentity,
    required this.workspaceLabel,
    required this.workspaceKind,
    required this.connectionState,
    this.lastConnectionError,
    this.taskId,
    this.displayStatus = 'idle',
    this.taskTitle,
    this.createdAt,
    this.updatedAt,
    this.archived = false,
    this.pinned = false,
    this.unreadAt,
  });

  factory Workspace.fromJson(Map<String, Object?> json) {
    // Canonical workspace key: `workspaceIdentity` when present, else the
    // path (docs/protocol/02). Entries never carry a workspaceKey field in
    // the payload; an explicit one wins if a future host sends it.
    final key = json['workspaceKey'] as String?;
    final path = json['workspacePath'] as String? ?? '';
    final identity = json['workspaceIdentity'] as String?;
    return Workspace(
      workspaceKey:
          key ?? (identity != null && identity.isNotEmpty ? identity : path),
      workspacePath: path,
      workspaceIdentity: json['workspaceIdentity'] as String?,
      workspaceLabel: json['workspaceLabel'] as String? ?? '',
      workspaceKind: json['workspaceKind'] as String? ?? 'local',
      connectionState: json['connectionState'] as String? ?? 'connected',
      lastConnectionError: json['lastConnectionError'] as String?,
      taskId: json['taskId'] as String?,
      displayStatus: json['displayStatus'] as String? ?? 'idle',
      taskTitle: json['title'] as String?,
      createdAt: json['createdAt'] as int?,
      updatedAt: json['updatedAt'] as int?,
      archived: json['archived'] as bool? ?? false,
      pinned: json['pinned'] as bool? ?? false,
      unreadAt: json['unreadAt'] as int?,
    );
  }

  bool get isRunning => displayStatus == 'running';
}

// ---------- Session (from sessions-index) ----------

class SessionSummary {
  final String sessionId;
  final String? parentSessionId;
  final String title;
  final String titleSource;
  final String phase;
  final bool sessionEnded;
  final bool hasBackgroundWork;
  final bool pendingInteraction;
  final String? pendingInteractionSummary;
  final String? goalStatus;
  final int? lastActivityAt;
  final String? lastAssistantPreview;
  final int? createdAt;

  const SessionSummary({
    required this.sessionId,
    this.parentSessionId,
    required this.title,
    required this.titleSource,
    required this.phase,
    required this.sessionEnded,
    required this.hasBackgroundWork,
    required this.pendingInteraction,
    this.pendingInteractionSummary,
    this.goalStatus,
    this.lastActivityAt,
    this.lastAssistantPreview,
    this.createdAt,
  });

  factory SessionSummary.fromJson(Map<String, Object?> json) => SessionSummary(
    sessionId: json['sessionId'] as String,
    parentSessionId: json['parentSessionId'] as String?,
    title: json['title'] as String? ?? '',
    titleSource: json['titleSource'] as String? ?? 'default',
    phase: json['phase'] as String? ?? '',
    sessionEnded: json['sessionEnded'] as bool? ?? false,
    hasBackgroundWork: json['hasBackgroundWork'] as bool? ?? false,
    pendingInteraction: json['pendingInteraction'] as bool? ?? false,
    pendingInteractionSummary: json['pendingInteractionSummary'] as String?,
    goalStatus: json['goalStatus'] as String?,
    lastActivityAt: json['lastActivityAt'] as int?,
    lastAssistantPreview: json['lastAssistantPreview'] as String?,
    createdAt: json['createdAt'] as int?,
  );
}

// ---------- Conversation rows ----------

sealed class ConversationRow {
  final int rowId;
  final String? turnId;
  final String? entityId;
  final int? createdAt;

  const ConversationRow({
    required this.rowId,
    this.turnId,
    this.entityId,
    this.createdAt,
  });

  factory ConversationRow.fromJson(Map<String, Object?> json) {
    final rowId = json['rowId'] as int? ?? 0;
    final turnId = json['turnId'] as String?;
    final entityId = json['entityId'] as String?;
    final createdAt = json['createdAt'] as int?;
    switch (json['kind']) {
      case 'turnHeader':
        return TurnHeaderRow.fromJson(json, rowId, turnId, entityId, createdAt);
      case 'userInput':
        return UserInputRow.fromJson(json, rowId, turnId, entityId, createdAt);
      case 'assistantText':
        return AssistantTextRow.fromJson(
          json,
          rowId,
          turnId,
          entityId,
          createdAt,
        );
      case 'reasoning':
        return ReasoningRow.fromJson(json, rowId, turnId, entityId, createdAt);
      case 'toolCall':
        return ToolCallRow.fromJson(json, rowId, turnId, entityId, createdAt);
      case 'subagent':
        return SubagentRow.fromJson(json, rowId, turnId, entityId, createdAt);
      case 'timelineMarker':
        return TimelineMarkerRow.fromJson(
          json,
          rowId,
          turnId,
          entityId,
          createdAt,
        );
      default:
        return UnknownRow(
          rowId: rowId,
          turnId: turnId,
          entityId: entityId,
          createdAt: createdAt,
          kind: json['kind']?.toString() ?? 'unknown',
        );
    }
  }

  /// Applies a row.delta append to this row's text at [path].
  ConversationRow withDelta(List<String> path, String append) => this;

  String get textForCache => '';

  /// Plain-text payload persisted by the offline cache (ADR-0002: text only).
  Map<String, Object?> toCacheMap() => {
    'rowId': rowId,
    'kind': _kindName(this),
  };
}

String _kindName(ConversationRow row) {
  if (row is TurnHeaderRow) return 'turnHeader';
  if (row is UserInputRow) return 'userInput';
  if (row is AssistantTextRow) return 'assistantText';
  if (row is ReasoningRow) return 'reasoning';
  if (row is ToolCallRow) return 'toolCall';
  if (row is SubagentRow) return 'subagent';
  if (row is TimelineMarkerRow) return 'timelineMarker';
  return 'unknown';
}

class TurnHeaderRow extends ConversationRow {
  final String origin; // userInput | ...
  final String state; // running | completed | ...
  final int? startedAt;
  final Map<String, Object?> raw;
  const TurnHeaderRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    this.origin = '',
    this.state = '',
    this.startedAt,
    required this.raw,
  });
  factory TurnHeaderRow.fromJson(
    Map<String, Object?> json,
    int rowId,
    String? turnId,
    String? entityId,
    int? createdAt,
  ) => TurnHeaderRow(
    rowId: rowId,
    turnId: turnId,
    entityId: entityId,
    createdAt: createdAt,
    origin: json['origin']?.toString() ?? '',
    state: json['state']?.toString() ?? '',
    startedAt: json['startedAt'] as int?,
    raw: json,
  );
}

/// One attachment carried by a user-input row (`attachments[]` in the row
/// schema: ref/fileName/mime/bytes/previewRef).
class RowAttachment {
  final String ref;
  final String fileName;
  final String mime;
  final int bytes;
  final String? previewRef;

  const RowAttachment({
    required this.ref,
    required this.fileName,
    required this.mime,
    required this.bytes,
    this.previewRef,
  });

  factory RowAttachment.fromJson(Map<String, Object?> json) => RowAttachment(
    ref: json['ref']?.toString() ?? '',
    fileName: json['fileName']?.toString() ?? '',
    mime: json['mime']?.toString() ?? '',
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    previewRef: json['previewRef']?.toString(),
  );

  bool get isImage => mime.startsWith('image/');
}

class UserInputRow extends ConversationRow {
  final String text;
  final List<RowAttachment> attachments;
  final Map<String, Object?> raw;
  const UserInputRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    required this.text,
    this.attachments = const [],
    required this.raw,
  });
  factory UserInputRow.fromJson(
    Map<String, Object?> json,
    int rowId,
    String? turnId,
    String? entityId,
    int? createdAt,
  ) => UserInputRow(
    rowId: rowId,
    turnId: turnId,
    entityId: entityId,
    createdAt: createdAt,
    text: json['inputText']?.toString() ?? json['text']?.toString() ?? '',
    attachments: [
      for (final a in (json['attachments'] as List? ?? const []))
        if (a is Map) RowAttachment.fromJson(a.cast<String, Object?>()),
    ],
    raw: json,
  );

  @override
  ConversationRow withDelta(List<String> path, String append) {
    if (path.length == 1 && path[0] == 'inputText') {
      return UserInputRow(
        rowId: rowId,
        turnId: turnId,
        entityId: entityId,
        createdAt: createdAt,
        text: text + append,
        attachments: attachments,
        raw: raw,
      );
    }
    return this;
  }

  @override
  String get textForCache => text;

  @override
  Map<String, Object?> toCacheMap() => {
    ...super.toCacheMap(),
    'inputText': text,
  };
}

class AssistantTextRow extends ConversationRow {
  final String text;
  final String state; // streaming | complete | interrupted | failed
  final String? model;
  final Map<String, Object?> raw;
  const AssistantTextRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    required this.text,
    required this.state,
    this.model,
    required this.raw,
  });
  factory AssistantTextRow.fromJson(
    Map<String, Object?> json,
    int rowId,
    String? turnId,
    String? entityId,
    int? createdAt,
  ) => AssistantTextRow(
    rowId: rowId,
    turnId: turnId,
    entityId: entityId,
    createdAt: createdAt,
    text: json['text']?.toString() ?? '',
    state: json['state']?.toString() ?? 'complete',
    model: json['model'] as String?,
    raw: json,
  );

  @override
  ConversationRow withDelta(List<String> path, String append) {
    if (path.length == 1 && path[0] == 'text') {
      return AssistantTextRow(
        rowId: rowId,
        turnId: turnId,
        entityId: entityId,
        createdAt: createdAt,
        text: text + append,
        state: state,
        model: model,
        raw: raw,
      );
    }
    return this;
  }

  @override
  String get textForCache => text;

  @override
  Map<String, Object?> toCacheMap() => {
    ...super.toCacheMap(),
    'text': text,
    'state': state,
  };
}

class ReasoningRow extends ConversationRow {
  final String text;
  final Map<String, Object?> raw;
  const ReasoningRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    required this.text,
    required this.raw,
  });
  factory ReasoningRow.fromJson(
    Map<String, Object?> json,
    int rowId,
    String? turnId,
    String? entityId,
    int? createdAt,
  ) => ReasoningRow(
    rowId: rowId,
    turnId: turnId,
    entityId: entityId,
    createdAt: createdAt,
    text: json['text']?.toString() ?? '',
    raw: json,
  );

  @override
  ConversationRow withDelta(List<String> path, String append) {
    if (path.length == 1 && path[0] == 'text') {
      return ReasoningRow(
        rowId: rowId,
        turnId: turnId,
        entityId: entityId,
        createdAt: createdAt,
        text: text + append,
        raw: raw,
      );
    }
    return this;
  }

  @override
  String get textForCache => text;

  @override
  Map<String, Object?> toCacheMap() => {...super.toCacheMap(), 'text': text};
}

class ToolCallRow extends ConversationRow {
  final String toolCallId;
  final String toolName;
  final String status;
  final String? inputText;
  final Map<String, Object?>? input;
  final String? output;
  final Map<String, Object?>? outputObj;
  final String? error;
  final int? startedAt;
  final int? endedAt;
  final Map<String, Object?> raw;
  const ToolCallRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    required this.toolCallId,
    required this.toolName,
    required this.status,
    this.inputText,
    this.input,
    this.output,
    this.outputObj,
    this.error,
    this.startedAt,
    this.endedAt,
    required this.raw,
  });
  factory ToolCallRow.fromJson(
    Map<String, Object?> json,
    int rowId,
    String? turnId,
    String? entityId,
    int? createdAt,
  ) {
    final outputVal = json['output'];
    String? outputText;
    Map<String, Object?>? outputObj;
    if (outputVal is String) {
      outputText = outputVal;
    } else if (outputVal is Map<String, Object?>) {
      outputObj = outputVal;
      outputText = outputVal['text']?.toString();
    }
    return ToolCallRow(
      rowId: rowId,
      turnId: turnId,
      entityId: entityId,
      createdAt: createdAt,
      toolCallId: json['toolCallId']?.toString() ?? '',
      toolName: json['toolName']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      inputText: json['inputText'] as String?,
      input: json['input'] is Map<String, Object?>
          ? json['input'] as Map<String, Object?>
          : null,
      output: outputText,
      outputObj: outputObj,
      error: json['error']?.toString(),
      startedAt: json['startedAt'] as int?,
      endedAt: json['endedAt'] as int?,
      raw: json,
    );
  }

  @override
  ConversationRow withDelta(List<String> path, String append) {
    if (path.length == 2 && path[0] == 'output' && path[1] == 'text') {
      final merged = {...raw, 'output': (output ?? '') + append};
      return ToolCallRow.fromJson(merged, rowId, turnId, entityId, createdAt);
    }
    if (path.length == 1 && path[0] == 'inputText') {
      final merged = {...raw, 'inputText': (inputText ?? '') + append};
      return ToolCallRow.fromJson(merged, rowId, turnId, entityId, createdAt);
    }
    return this;
  }

  @override
  String get textForCache => [inputText, output].whereType<String>().join('\n');

  @override
  Map<String, Object?> toCacheMap() => {
    ...super.toCacheMap(),
    if (inputText != null) 'inputText': inputText,
    if (output != null) 'output': output,
    'toolName': toolName,
    'toolStatus': status,
  };
}

class SubagentRow extends ConversationRow {
  final String subagentType;
  final String status; // running | success | error
  final String summaryText;
  final Map<String, Object?> raw;
  const SubagentRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    this.subagentType = '',
    this.status = '',
    this.summaryText = '',
    required this.raw,
  });
  factory SubagentRow.fromJson(
    Map<String, Object?> json,
    int rowId,
    String? turnId,
    String? entityId,
    int? createdAt,
  ) => SubagentRow(
    rowId: rowId,
    turnId: turnId,
    entityId: entityId,
    createdAt: createdAt,
    subagentType: json['subagentType']?.toString() ?? '',
    status: json['status']?.toString() ?? '',
    summaryText:
        json['summaryText']?.toString() ?? json['summary']?.toString() ?? '',
    raw: json,
  );

  @override
  String get textForCache => summaryText;
}

class TimelineMarkerRow extends ConversationRow {
  final String markerType; // compact | ...
  final int? tokensBefore;
  final int? tokensAfter;
  final Map<String, Object?> raw;
  const TimelineMarkerRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    this.markerType = '',
    this.tokensBefore,
    this.tokensAfter,
    required this.raw,
  });
  factory TimelineMarkerRow.fromJson(
    Map<String, Object?> json,
    int rowId,
    String? turnId,
    String? entityId,
    int? createdAt,
  ) {
    final marker = json['marker'];
    String markerType = '';
    int? tokensBefore;
    int? tokensAfter;
    if (marker is Map) {
      markerType = marker['type']?.toString() ?? '';
      tokensBefore = marker['tokensBefore'] is int
          ? marker['tokensBefore'] as int
          : null;
      tokensAfter = marker['tokensAfter'] is int
          ? marker['tokensAfter'] as int
          : null;
    }
    return TimelineMarkerRow(
      rowId: rowId,
      turnId: turnId,
      entityId: entityId,
      createdAt: createdAt,
      markerType: markerType,
      tokensBefore: tokensBefore,
      tokensAfter: tokensAfter,
      raw: json,
    );
  }
}

class UnknownRow extends ConversationRow {
  final String kind;
  const UnknownRow({
    required super.rowId,
    super.turnId,
    super.entityId,
    super.createdAt,
    required this.kind,
  });
}

// ---------- Conversation state ----------

class ConversationSnapshot {
  final String sessionId;
  final String logEpoch;
  final int seq;
  final int revision;
  final Map<String, Object?> control;
  final Map<String, Object?>? availability;
  final Map<String, Object?>? inputRouting;
  final Map<String, Object?>? meta;
  final Map<String, Object?>? config;
  /// Held queue (`{items: [{queueItemId, text, …}], autoDrain,
  /// pauseReason?}`). Items other than queueItemId/text are passed through
  /// verbatim — the client only reads those two keys.
  final Map<String, Object?>? queue;
  /// Live TodoWrite state (`{items: [{id, content, status}], updatedAt}`)
  /// — the authoritative todo list, delivered via conversation frames
  /// (status uses `inProgress` camelCase here, unlike readSession `todos`).
  final Map<String, Object?>? plan;
  /// Live token usage (`{contextWindow: {usedTokens, maxTokens, cache,
  /// breakdown}, cumulative}`) — the web client's chat-header cache-hit-rate
  /// row reads `contextWindow.cache.hitRate` from here, so this is the source
  /// the token sheet mirrors for 平均缓存命中率.
  final Map<String, Object?>? usage;
  final List<Map<String, Object?>> pendingInteractions;
  final List<Map<String, Object?>> pendingCommands;
  final List<ConversationRow> rows;
  final int totalCount;
  final int firstRowId;

  const ConversationSnapshot({
    required this.sessionId,
    required this.logEpoch,
    required this.seq,
    required this.revision,
    required this.control,
    this.availability,
    this.inputRouting,
    this.meta,
    this.config,
    this.queue,
    this.plan,
    this.usage,
    required this.pendingInteractions,
    required this.pendingCommands,
    required this.rows,
    required this.totalCount,
    required this.firstRowId,
  });

  factory ConversationSnapshot.fromJson(Map<String, Object?> json) {
    final rowsJson = json['rows'];
    final rows = rowsJson is Map<String, Object?> && rowsJson['window'] is List
        ? (rowsJson['window'] as List)
              .whereType<Map<String, Object?>>()
              .map(ConversationRow.fromJson)
              .toList()
        : <ConversationRow>[];
    final interactions = json['pendingInteractions'] is List
        ? (json['pendingInteractions'] as List)
              .whereType<Map<String, Object?>>()
              .toList()
        : <Map<String, Object?>>[];
    final pendingCommands = json['pendingCommands'] is List
        ? (json['pendingCommands'] as List)
              .whereType<Map<String, Object?>>()
              .toList()
        : <Map<String, Object?>>[];
    return ConversationSnapshot(
      sessionId: json['sessionId']?.toString() ?? '',
      logEpoch: json['logEpoch']?.toString() ?? '',
      seq: json['seq'] as int? ?? 0,
      revision: json['revision'] as int? ?? 0,
      control: json['control'] is Map<String, Object?>
          ? json['control'] as Map<String, Object?>
          : const {},
      availability: json['availability'] is Map<String, Object?>
          ? json['availability'] as Map<String, Object?>
          : null,
      inputRouting: json['inputRouting'] is Map<String, Object?>
          ? json['inputRouting'] as Map<String, Object?>
          : null,
      meta: json['meta'] is Map<String, Object?>
          ? json['meta'] as Map<String, Object?>
          : null,
      config: json['config'] is Map<String, Object?>
          ? json['config'] as Map<String, Object?>
          : null,
      queue: json['queue'] is Map<String, Object?>
          ? json['queue'] as Map<String, Object?>
          : null,
      plan: json['plan'] is Map<String, Object?>
          ? json['plan'] as Map<String, Object?>
          : null,
      usage: json['usage'] is Map<String, Object?>
          ? json['usage'] as Map<String, Object?>
          : null,
      pendingInteractions: interactions,
      pendingCommands: pendingCommands,
      rows: rows,
      totalCount: rowsJson is Map<String, Object?>
          ? rowsJson['totalCount'] as int? ?? rows.length
          : rows.length,
      firstRowId: rowsJson is Map<String, Object?>
          ? rowsJson['firstRowId'] as int? ?? 0
          : 0,
    );
  }
}

/// A deltas payload: sequence of row/state operations.
class ConversationDeltas {
  final List<Map<String, Object?>> ops;
  const ConversationDeltas(this.ops);
}

/// One selectable option of a pending interaction. Permission options carry a
/// `kind` (allowOnce | allowAlways | deny | custom); plain userInput options
/// only have optionId/label.
class InteractionOption {
  final String optionId;
  final String label;
  final String kind;

  const InteractionOption({
    required this.optionId,
    required this.label,
    this.kind = '',
  });

  factory InteractionOption.fromJson(Map<String, Object?> json) =>
      InteractionOption(
        optionId: json['optionId']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
      );
}

/// One option inside an AskUserQuestion question (`{value,label,description?}`
/// — note the key is `value`, not `optionId`).
class InteractionQuestionOption {
  final String value;
  final String label;
  final String description;

  const InteractionQuestionOption({
    required this.value,
    required this.label,
    this.description = '',
  });

  factory InteractionQuestionOption.fromJson(Map<String, Object?> json) =>
      InteractionQuestionOption(
        value: json['value']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
      );
}

/// One question of an AskUserQuestion-style userInput interaction
/// (`{question, header, options, multiSelect?}`).
class InteractionQuestion {
  final String question;
  final String header;
  final List<InteractionQuestionOption> options;
  final bool multiSelect;

  const InteractionQuestion({
    required this.question,
    required this.header,
    required this.options,
    required this.multiSelect,
  });

  factory InteractionQuestion.fromJson(Map<String, Object?> json) =>
      InteractionQuestion(
        question: json['question']?.toString() ?? '',
        header: json['header']?.toString() ?? '',
        options: json['options'] is List
            ? (json['options'] as List)
                  .whereType<Map<String, Object?>>()
                  .map(InteractionQuestionOption.fromJson)
                  .toList()
            : const [],
        multiSelect: json['multiSelect'] as bool? ?? false,
      );
}

/// A pending interaction from the conversation snapshot. Two payload shapes
/// (probe-confirmed against the desktop's zod schemas):
///
/// - permission: `{kind, toolCallId, toolName, summary, detail, options:
///   [{optionId,label,kind,response?}]}`
/// - userInput: `{kind, prompt, freeText, options?: [{optionId,label}],
///   toolName?, questions?: [{question,header,options,multiSelect}], ...}`
///   — AskUserQuestion surfaces as a userInput with a `questions` array.
class PendingInteraction {
  final String interactionId;
  final String kind; // permission | userInput
  final int? anchorRowId;
  final Map<String, Object?> payload;

  const PendingInteraction({
    required this.interactionId,
    required this.kind,
    this.anchorRowId,
    required this.payload,
  });

  factory PendingInteraction.fromJson(Map<String, Object?> json) =>
      PendingInteraction(
        interactionId: json['interactionId']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'userInput',
        anchorRowId: json['anchorRowId'] as int?,
        payload: json['payload'] is Map<String, Object?>
            ? json['payload'] as Map<String, Object?>
            : const {},
      );

  bool get isPermission => kind == 'permission';

  /// userInput: the free-text prompt. Permission: the human-readable summary
  /// of what the tool wants to do.
  String get prompt =>
      payload['prompt']?.toString() ?? payload['summary']?.toString() ?? '';

  /// Raw permission detail (tool input etc.) for display.
  String get detail {
    final d = payload['detail'];
    if (d == null) return '';
    return d is String ? d : jsonEncode(d);
  }

  bool get freeText => payload['freeText'] as bool? ?? false;

  List<InteractionOption> get options => payload['options'] is List
      ? (payload['options'] as List)
            .whereType<Map<String, Object?>>()
            .map(InteractionOption.fromJson)
            .toList()
      : const [];

  List<InteractionQuestion> get questions => payload['questions'] is List
      ? (payload['questions'] as List)
            .whereType<Map<String, Object?>>()
            .map(InteractionQuestion.fromJson)
            .toList()
      : const [];

  bool get hasQuestions => questions.isNotEmpty;

  String? get toolName => payload['toolName'] as String?;
}

/// Builds the resolveInteraction `answer.content` for an AskUserQuestion card,
/// mirroring the desktop web client exactly: `answers` maps each question to
/// its joined values, `answer_<i>` carries the per-question value (a list for
/// multiSelect, a single string otherwise), and a lone question also fills
/// `answer`. [selections] maps question text to the chosen values (selected
/// options plus any custom free-text entry).
Map<String, Object?> buildQuestionAnswerContent(
  List<InteractionQuestion> questions,
  Map<String, List<String>> selections,
) {
  List<String> valuesFor(InteractionQuestion q) =>
      selections[q.question]?.where((v) => v.trim().isNotEmpty).toList() ??
      const [];

  final content = <String, Object?>{};
  final answers = <String, Object?>{};
  for (final q in questions) {
    final values = valuesFor(q);
    if (values.isNotEmpty) answers[q.question] = values.join(', ');
  }
  content['answers'] = answers;
  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    final values = valuesFor(q);
    if (values.isNotEmpty) {
      content['answer_$i'] = q.multiSelect ? values : values.first;
    }
  }
  if (questions.length == 1) {
    final q = questions.first;
    final values = valuesFor(q);
    if (values.isNotEmpty) {
      content['answer'] = q.multiSelect ? values : values.first;
    }
  }
  return content;
}

// ---------- readSession polling models (event push never arrives) ----------

/// One pending request from `readSession().projection.pendingPermissions`.
/// Covers both tool permissions (Bash, Read, …) and AskUserQuestion — the
/// desktop's web client derives its pendingInteractions from exactly this
/// array, so `requestId` is the id to pass to resolveInteraction.
class PendingRequest {
  final String requestId;
  final String? toolCallId;
  final String toolName;
  final String reason;
  final String riskLevel;
  final Map<String, Object?> input;
  final List<PendingRequestOption> options;
  final int? requestedAt;
  /// Who requested the approval. `{kind: "subagent", agentId, agentType,
  /// childSessionId, parentSessionId, parentToolCallId?, …}` when a subagent
  /// (child session) raised the request — the UI marks those entries with a
  /// badge. Absent for main-agent requests.
  final Map<String, Object?>? origin;

  const PendingRequest({
    required this.requestId,
    this.toolCallId,
    this.toolName = '',
    this.reason = '',
    this.riskLevel = '',
    this.input = const {},
    this.options = const [],
    this.requestedAt,
    this.origin,
  });

  factory PendingRequest.fromJson(Map<String, Object?> json) => PendingRequest(
    requestId: json['requestId']?.toString() ?? '',
    toolCallId: json['toolCallId']?.toString(),
    toolName: json['toolName']?.toString() ?? '',
    reason: json['reason']?.toString() ?? '',
    riskLevel: json['riskLevel']?.toString() ?? '',
    input: json['input'] is Map<String, Object?>
        ? json['input'] as Map<String, Object?>
        : const {},
    options: json['options'] is List
        ? (json['options'] as List)
              .whereType<Map<String, Object?>>()
              .map(PendingRequestOption.fromJson)
              .toList()
        : const [],
    requestedAt: json['requestedAt'] as int?,
    origin: json['origin'] is Map<String, Object?>
        ? json['origin'] as Map<String, Object?>
        : null,
  );

  /// True when the request was raised by a subagent (child session) rather
  /// than the main agent — the sheet shows a badge on those pages.
  bool get isFromSubagent => origin?['kind'] == 'subagent';

  /// AskUserQuestion requests carry `input.questions`.
  List<InteractionQuestion> get questions => input['questions'] is List
      ? (input['questions'] as List)
            .whereType<Map<String, Object?>>()
            .map(InteractionQuestion.fromJson)
            .toList()
      : const [];

  bool get hasQuestions => questions.isNotEmpty;

  /// Plan-approval elicitation (ExitPlanMode): `input.interaction ==
  /// "plan_approval"` with a plan summary in `input.plan`.
  bool get isExitPlanMode =>
      toolName == 'ExitPlanMode' || input['interaction'] == 'plan_approval';

  /// Free-text elicitation: the runtime's userInput interaction with
  /// `freeText: true` and a `prompt` but no `questions`. Permission entries
  /// (tool args in `input`) never carry `freeText: true`.
  bool get isFreeTextInput =>
      !hasQuestions && input['freeText'] == true && input['prompt'] is String;

  /// True for anything the user must answer textually (as opposed to an
  /// allow/deny permission): AskUserQuestion, ExitPlanMode, free-text input.
  bool get isElicitation =>
      hasQuestions ||
      toolName == 'AskUserQuestion' ||
      isExitPlanMode ||
      isFreeTextInput;

  /// Human-readable label for a permission option's `kind`
  /// (`allow_once`/`allowOnce` | `allow_always`/`allowAlways` | `deny` |
  /// `custom`).
  static String optionKindLabel(String kind) {
    switch (kind) {
      case 'allow_once':
      case 'allowOnce':
        return '允许一次';
      case 'allow_always':
      case 'allowAlways':
        return '始终允许';
      case 'deny':
        return '拒绝';
      case 'custom':
        return '自定义';
      default:
        return '';
    }
  }

  /// Permission prompt: the tool's human-readable reason.
  String get prompt {
    if (reason.isNotEmpty) return reason;
    return toolName.isEmpty ? '需要你的批准' : '允许 $toolName 执行吗？';
  }
}

/// One option of a [PendingRequest] — carries the `response` the host applies
/// when this option is chosen (`{decision, reason, permissionUpdates}`).
class PendingRequestOption {
  final String optionId;
  final String kind; // allow_once | allow_always | deny | custom
  final String name;
  final String description;
  final Map<String, Object?> response;

  const PendingRequestOption({
    required this.optionId,
    this.kind = '',
    this.name = '',
    this.description = '',
    this.response = const {},
  });

  factory PendingRequestOption.fromJson(Map<String, Object?> json) =>
      PendingRequestOption(
        optionId: json['optionId']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        response: json['response'] is Map<String, Object?>
            ? json['response'] as Map<String, Object?>
            : const {},
      );
}

/// One line of the context-usage breakdown. `source` is one of
/// messages | system_prompt | meta_user_context | skills | tool_prompt |
/// system_tool_schemas | mcp_tool_schemas; `chars` is a character count the
/// desktop uses for the percentage bar.
class ContextBreakdownEntry {
  final String source;
  final int chars;

  const ContextBreakdownEntry({required this.source, required this.chars});

  factory ContextBreakdownEntry.fromJson(Map<String, Object?> json) =>
      ContextBreakdownEntry(
        source: json['source']?.toString() ?? '',
        chars: json['chars'] as int? ?? 0,
      );
}

/// `readSession().runtime.contextUsage` — the context-window fill and cache
/// stats. `breakdown` is only present while the session is live.
class ContextUsage {
  final int used;
  final int size;
  final List<ContextBreakdownEntry> breakdown;
  final Map<String, Object?>? cache;

  const ContextUsage({
    this.used = 0,
    this.size = 0,
    this.breakdown = const [],
    this.cache,
  });

  factory ContextUsage.fromJson(Map<String, Object?>? json) {
    if (json == null) return const ContextUsage();
    return ContextUsage(
      used: json['used'] as int? ?? 0,
      size: json['size'] as int? ?? 0,
      breakdown: json['breakdown'] is List
          ? (json['breakdown'] as List)
                .whereType<Map<String, Object?>>()
                .map(ContextBreakdownEntry.fromJson)
                .toList()
          : const [],
      cache: json['cache'] is Map<String, Object?>
          ? json['cache'] as Map<String, Object?>
          : null,
    );
  }

  double? get fillRatio => size <= 0 ? null : (used / size).clamp(0.0, 1.0);

  /// Average cache hit rate: the runtime's rolling `hitRate` — the same field
  /// the desktop chat header displays. Null when the runtime produced none
  /// (the token sheet then shows an em dash instead of a derived ratio).
  double? get cacheHitRate {
    final hit = cache?['hitRate'];
    if (hit is num) return hit.toDouble().clamp(0.0, 1.0);
    return null;
  }
}

/// `snapshot.usage` — live token usage pushed in conversation snapshots and
/// `state.updated` patches (doc 05). The web client's chat header reads
/// `contextWindow.cache.hitRate` from this object for its cache-hit-rate row,
/// so this is the source the token sheet mirrors for 平均缓存命中率.
class ConversationUsage {
  final int? usedTokens;
  final int? maxTokens;
  final int? autoCompactThresholdTokens;
  final Map<String, Object?>? cache;
  final List<ContextBreakdownEntry> breakdown;
  final Map<String, Object?>? cumulative;

  const ConversationUsage({
    this.usedTokens,
    this.maxTokens,
    this.autoCompactThresholdTokens,
    this.cache,
    this.breakdown = const [],
    this.cumulative,
  });

  factory ConversationUsage.fromJson(Map<String, Object?>? json) {
    if (json == null) return const ConversationUsage();
    final window = json['contextWindow'];
    final windowMap = window is Map<String, Object?> ? window : null;
    final cache = windowMap?['cache'];
    final breakdownJson = windowMap?['breakdown'];
    return ConversationUsage(
      usedTokens: windowMap?['usedTokens'] as int?,
      maxTokens: windowMap?['maxTokens'] as int?,
      autoCompactThresholdTokens:
          windowMap?['autoCompactThresholdTokens'] as int?,
      cache: cache is Map<String, Object?> ? cache : null,
      breakdown: breakdownJson is List
          ? breakdownJson
                .whereType<Map<String, Object?>>()
                .map(ContextBreakdownEntry.fromJson)
                .toList()
          : const [],
      cumulative: json['cumulative'] is Map<String, Object?>
          ? json['cumulative'] as Map<String, Object?>
          : null,
    );
  }

  /// Rolling average cache hit rate from `contextWindow.cache.hitRate` — the
  /// exact field the desktop chat header displays. Null when the runtime has
  /// not produced a hit rate yet.
  double? get cacheHitRate {
    final hit = cache?['hitRate'];
    if (hit is num) return hit.toDouble().clamp(0.0, 1.0);
    return null;
  }
}

/// `readSession().settings` — the current model and thought level plus the
/// workspace's available options.
class SessionModelConfig {
  final String? provider;
  final String? model;
  final String? thoughtLevel;

  /// Collaboration mode (build/edit/plan/yolo) from `settings.mode.current`.
  final String? mode;
  final List<ModelOption> availableModels;
  final List<ThoughtLevelOption> availableThoughtLevels;

  const SessionModelConfig({
    this.provider,
    this.model,
    this.thoughtLevel,
    this.mode,
    this.availableModels = const [],
    this.availableThoughtLevels = const [],
  });

  factory SessionModelConfig.fromSettings(Map<String, Object?>? settings) {
    if (settings == null) return const SessionModelConfig();
    final model = settings['model'];
    final thought = settings['thoughtLevel'];
    final mode = settings['mode'];
    return SessionModelConfig(
      provider: model is Map<String, Object?>
          ? (model['current'] is Map<String, Object?>
                ? (model['current'] as Map<String, Object?>)['providerId']
                      ?.toString()
                : null)
          : null,
      model: model is Map<String, Object?>
          ? (model['current'] is Map<String, Object?>
                ? (model['current'] as Map<String, Object?>)['modelId']
                      ?.toString()
                : null)
          : null,
      thoughtLevel: thought is Map<String, Object?>
          ? thought['current']?.toString()
          : null,
      mode: mode is Map<String, Object?> ? mode['current']?.toString() : null,
      availableModels:
          model is Map<String, Object?> && model['available'] is List
          ? (model['available'] as List)
                .whereType<Map<String, Object?>>()
                .map(ModelOption.fromJson)
                .toList()
          : const [],
      availableThoughtLevels:
          thought is Map<String, Object?> && thought['available'] is List
          ? (thought['available'] as List)
                .whereType<Map<String, Object?>>()
                .map(ThoughtLevelOption.fromJson)
                .toList()
          : const [],
    );
  }

  String get currentModelLabel {
    for (final m in availableModels) {
      if (m.provider == provider && m.model == model) return m.label;
    }
    return model ?? '未知模型';
  }
}

class ModelOption {
  final String provider;
  final String model;
  final String label;
  final String? providerLabel;
  final int? contextWindow;
  final List<ThoughtLevelOption> reasoningLevels;

  const ModelOption({
    required this.provider,
    required this.model,
    this.label = '',
    this.providerLabel,
    this.contextWindow,
    this.reasoningLevels = const [],
  });

  factory ModelOption.fromJson(Map<String, Object?> json) {
    final ref = json['ref'] is Map<String, Object?>
        ? json['ref'] as Map<String, Object?>
        : const <String, Object?>{};
    final reasoning = json['reasoning'] is Map<String, Object?>
        ? json['reasoning'] as Map<String, Object?>
        : null;
    return ModelOption(
      provider: ref['providerId']?.toString() ?? '',
      model: ref['modelId']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      providerLabel: json['providerLabel']?.toString(),
      contextWindow: json['contextWindow'] as int?,
      reasoningLevels: reasoning != null && reasoning['levels'] is List
          ? (reasoning['levels'] as List)
                .whereType<Map<String, Object?>>()
                .map(ThoughtLevelOption.fromJson)
                .toList()
          : const [],
    );
  }
}

class ThoughtLevelOption {
  final String value;
  final String label;

  const ThoughtLevelOption({required this.value, this.label = ''});

  factory ThoughtLevelOption.fromJson(Map<String, Object?> json) =>
      ThoughtLevelOption(
        value: json['value']?.toString() ?? '',
        label: json['label']?.toString() ?? json['value']?.toString() ?? '',
      );
}
