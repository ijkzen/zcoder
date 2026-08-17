import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';

void main() {
  group('PendingRequest (readSession pendingPermissions)', () {
    test('parses an AskUserQuestion permission with questions', () {
      final req = PendingRequest.fromJson({
        'requestId': 'perm_abc123',
        'toolCallId': 'tool_xyz',
        'toolName': 'AskUserQuestion',
        'reason': 'Tool AskUserQuestion requires user interaction',
        'riskLevel': 'low',
        'input': {
          'questions': [
            {
              'question': '喜欢A还是B？',
              'header': '测试',
              'options': [
                {'label': 'A', 'description': '选项 A', 'value': 'a'},
                {'label': 'B', 'description': '选项 B', 'value': 'b'},
              ],
              'multiSelect': false,
            },
          ],
        },
        'options': [
          {
            'optionId': 'allow_once',
            'kind': 'allow_once',
            'name': 'Allow once',
            'response': {'decision': 'allow'},
          },
        ],
        'requestedAt': 1786847264122,
      });

      expect(req.requestId, 'perm_abc123');
      expect(req.toolCallId, 'tool_xyz');
      expect(req.isElicitation, isTrue);
      expect(req.hasQuestions, isTrue);
      expect(req.questions, hasLength(1));
      final q = req.questions.first;
      expect(q.question, '喜欢A还是B？');
      expect(q.header, '测试');
      expect(q.options, hasLength(2));
      expect(q.options.first.value, 'a');
      expect(q.options.first.label, 'A');
      expect(q.multiSelect, isFalse);
      expect(req.options.single.optionId, 'allow_once');
      expect(req.options.single.kind, 'allow_once');
      expect(req.requestedAt, 1786847264122);
    });

    test('parses a plain tool permission (not an elicitation)', () {
      final req = PendingRequest.fromJson({
        'requestId': 'perm_bash',
        'toolName': 'Bash',
        'reason': 'Bash requires approval',
        'input': {'command': 'rm -rf /tmp/x'},
        'options': [
          {'optionId': 'allow_once', 'kind': 'allow_once', 'name': 'Allow once'},
          {'optionId': 'allow_project', 'kind': 'allow_always', 'name': 'Always allow'},
          {'optionId': 'deny', 'kind': 'deny', 'name': 'Deny'},
        ],
      });

      expect(req.isElicitation, isFalse);
      expect(req.hasQuestions, isFalse);
      expect(req.prompt, 'Bash requires approval');
      expect(req.options, hasLength(3));
      expect(req.options[1].kind, 'allow_always');
    });

    test('parses a subagent origin as isFromSubagent', () {
      final req = PendingRequest.fromJson({
        'requestId': 'perm_subagent',
        'toolName': 'Bash',
        'reason': '子智能体请求执行 bash',
        'input': {'command': 'ls'},
        'options': [
          {'optionId': 'allow_once', 'kind': 'allow_once', 'name': 'Allow once'},
          {'optionId': 'deny', 'kind': 'deny', 'name': 'Deny'},
        ],
        'origin': {
          'kind': 'subagent',
          'agentId': 'agent_explore',
          'agentType': 'explore',
          'childSessionId': 'sess_child',
          'parentSessionId': 'sess_parent',
          'parentToolCallId': 'tool_task',
        },
      });

      expect(req.isFromSubagent, isTrue);
      expect(req.origin?['childSessionId'], 'sess_child');
      expect(req.isElicitation, isFalse);
    });

    test('missing origin stays a main-agent request', () {
      final req = PendingRequest.fromJson({
        'requestId': 'perm_main',
        'toolName': 'Bash',
        'reason': 'Bash requires approval',
        'options': [
          {'optionId': 'allow_once', 'kind': 'allow_once', 'name': 'Allow once'},
        ],
      });

      expect(req.origin, isNull);
      expect(req.isFromSubagent, isFalse);
    });
  });

  group('ContextUsage', () {
    test('computes fill ratio and cache hit rate', () {
      final usage = ContextUsage.fromJson({
        'used': 328979,
        'size': 1000000,
        'cost': null,
        'breakdown': [
          {'source': 'system_prompt', 'chars': 8802},
          {'source': 'system_tool_schemas', 'chars': 79687},
          {'source': 'mcp_tool_schemas', 'chars': 57232},
          {'source': 'skills', 'chars': 15467},
          {'source': 'messages', 'chars': 1475064},
        ],
        'cache': {
          'hitRate': 0.9983,
          'cacheReadTokens': 172032,
          'inputTokens': 172323,
        },
      });

      expect(usage.fillRatio, closeTo(0.329, 0.001));
      expect(usage.breakdown, hasLength(5));
      expect(usage.breakdown.first.source, 'system_prompt');
      expect(usage.cacheHitRate, closeTo(0.9983, 0.0001));
    });

    test('cache without hitRate stays null (no derived ratio)', () {
      final usage = ContextUsage.fromJson({
        'used': 100,
        'size': 200,
        'cache': {'cacheReadTokens': 80, 'inputTokens': 100},
      });
      expect(usage.cacheHitRate, isNull);
    });

    test('empty input stays null-safe', () {
      const usage = ContextUsage();
      expect(usage.fillRatio, isNull);
      expect(usage.cacheHitRate, isNull);
      expect(usage.breakdown, isEmpty);
    });
  });

  group('ConversationUsage (snapshot usage.contextWindow)', () {
    test('parses contextWindow.cache.hitRate', () {
      final usage = ConversationUsage.fromJson({
        'contextWindow': {
          'usedTokens': 107654,
          'maxTokens': 1000000,
          'autoCompactThresholdTokens': null,
          'cache': {'hitRate': 0.981, 'hitRateRequestCount': 46},
          'breakdown': [
            {'source': 'messages', 'chars': 68000},
            {'source': 'system_tool_schemas', 'chars': 18000},
          ],
        },
        'cumulative': {
          'inputTokens': 107800,
          'outputTokens': 26500,
          'cacheReadTokens': 128,
          'cacheWriteTokens': 0,
        },
      });

      expect(usage.usedTokens, 107654);
      expect(usage.maxTokens, 1000000);
      expect(usage.cacheHitRate, closeTo(0.981, 0.0001));
      expect(usage.breakdown, hasLength(2));
      expect(usage.breakdown.first.source, 'messages');
      expect(usage.cumulative?['cacheReadTokens'], 128);
    });

    test('no contextWindow/cache stays null-safe', () {
      const usage = ConversationUsage();
      expect(usage.usedTokens, isNull);
      expect(usage.cacheHitRate, isNull);
      expect(usage.breakdown, isEmpty);
      expect(ConversationUsage.fromJson(null).cacheHitRate, isNull);
      expect(
        ConversationUsage.fromJson({'contextWindow': null}).cacheHitRate,
        isNull,
      );
    });
  });

  group('ConversationSnapshot usage passthrough', () {
    test('carries the usage field for the token sheet', () {
      final snapshot = ConversationSnapshot.fromJson({
        'sessionId': 's1',
        'logEpoch': 'e1',
        'seq': 1,
        'revision': 0,
        'control': const {},
        'usage': {
          'contextWindow': {
            'usedTokens': 9000,
            'maxTokens': 1000000,
            'cache': {'hitRate': 0.95},
          },
          'cumulative': const {},
        },
        'rows': {'window': const [], 'totalCount': 0, 'firstRowId': 0},
        'pendingInteractions': const [],
        'pendingCommands': const [],
      });
      expect(snapshot.usage, isNotNull);
      expect(
        ConversationUsage.fromJson(snapshot.usage).cacheHitRate,
        closeTo(0.95, 0.0001),
      );
    });
  });

  group('SessionModelConfig', () {
    test('parses current model and thought level from readSession settings', () {
      final config = SessionModelConfig.fromSettings({
        'model': {
          'current': {'providerId': 'p1', 'modelId': 'm1'},
          'available': [
            {
              'ref': {'providerId': 'p1', 'modelId': 'm1'},
              'label': 'model-one',
              'providerLabel': 'Provider',
              'contextWindow': 262144,
              'reasoning': {
                'enabled': true,
                'levels': [
                  {'value': 'low', 'label': 'low'},
                  {'value': 'high', 'label': 'high'},
                ],
              },
            },
          ],
        },
        'thoughtLevel': {
          'enabled': true,
          'current': 'high',
          'available': [
            {'value': 'off', 'label': 'off'},
            {'value': 'high', 'label': 'high'},
          ],
        },
      });

      expect(config.provider, 'p1');
      expect(config.model, 'm1');
      expect(config.thoughtLevel, 'high');
      expect(config.availableModels, hasLength(1));
      expect(config.availableModels.first.label, 'model-one');
      expect(config.availableModels.first.contextWindow, 262144);
      expect(config.availableModels.first.reasoningLevels, hasLength(2));
      expect(config.availableThoughtLevels, hasLength(2));
      expect(config.availableThoughtLevels.first.value, 'off');
      expect(config.currentModelLabel, 'model-one');
    });

    test('unknown current model falls back to raw id', () {
      final config = SessionModelConfig.fromSettings({
        'model': {'current': {'providerId': 'p9', 'modelId': 'm9'}},
      });
      expect(config.currentModelLabel, 'm9');
    });
  });

  group('buildQuestionAnswerContent', () {
    test('single question fills answers/answer_0/answer', () {
      final questions = [
        InteractionQuestion(
          question: '喜欢A还是B？',
          header: '测试',
          options: const [],
          multiSelect: false,
        ),
      ];
      final content = buildQuestionAnswerContent(questions, {
        '喜欢A还是B？': ['A'],
      });
      expect(content['answers'], {'喜欢A还是B？': 'A'});
      expect(content['answer_0'], 'A');
      expect(content['answer'], 'A');
    });

    test('multiSelect packs a list', () {
      final questions = [
        InteractionQuestion(
          question: '多选',
          header: '',
          options: const [],
          multiSelect: true,
        ),
      ];
      final content = buildQuestionAnswerContent(questions, {
        '多选': ['a', 'b'],
      });
      expect(content['answer_0'], ['a', 'b']);
      expect(content['answer'], ['a', 'b']);
    });
  });
}
