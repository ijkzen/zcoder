import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote/src/protocol/topics/topic_models.dart';

/// Guards the pending-interaction parsing/answering contract against the
/// desktop's zod schemas (permission & userInput payloads, and the
/// AskUserQuestion answer content shape the web client sends).
void main() {
  group('PendingInteraction parsing', () {
    test('permission payload: summary/detail/options with kinds', () {
      final interaction = PendingInteraction.fromJson({
        'interactionId': 'int_1',
        'kind': 'permission',
        'anchorRowId': 42,
        'createdAt': 1786830000000,
        'payload': {
          'kind': 'permission',
          'toolCallId': 'tc_1',
          'toolName': 'Bash',
          'summary': '执行 rm -rf build/',
          'detail': {'command': 'rm -rf build/'},
          'options': [
            {'optionId': 'o1', 'label': '允许一次', 'kind': 'allowOnce'},
            {'optionId': 'o2', 'label': '始终允许', 'kind': 'allowAlways'},
            {'optionId': 'o3', 'label': '拒绝', 'kind': 'deny'},
          ],
        },
      });
      expect(interaction.isPermission, isTrue);
      expect(interaction.toolName, 'Bash');
      expect(interaction.prompt, '执行 rm -rf build/');
      expect(interaction.detail, contains('rm -rf build/'));
      expect(interaction.options, hasLength(3));
      expect(interaction.options[1].kind, 'allowAlways');
      expect(interaction.options[2].kind, 'deny');
      expect(interaction.hasQuestions, isFalse);
    });

    test('userInput payload with questions (AskUserQuestion)', () {
      final interaction = PendingInteraction.fromJson({
        'interactionId': 'int_2',
        'kind': 'userInput',
        'payload': {
          'kind': 'userInput',
          'prompt': '',
          'freeText': false,
          'toolName': 'AskUserQuestion',
          'toolCallId': 'tc_2',
          'questions': [
            {
              'question': '选择哪种方案？',
              'header': '方案',
              'multiSelect': false,
              'options': [
                {'value': 'a', 'label': '方案 A', 'description': '稳妥'},
                {'value': 'b', 'label': '方案 B'},
              ],
            },
            {
              'question': '需要哪些平台？',
              'header': '平台',
              'multiSelect': true,
              'options': [
                {'value': 'android', 'label': 'Android'},
                {'value': 'ios', 'label': 'iOS'},
              ],
            },
          ],
        },
      });
      expect(interaction.isPermission, isFalse);
      expect(interaction.hasQuestions, isTrue);
      final questions = interaction.questions;
      expect(questions, hasLength(2));
      expect(questions[0].header, '方案');
      expect(questions[0].multiSelect, isFalse);
      expect(questions[0].options[0].value, 'a');
      expect(questions[0].options[0].description, '稳妥');
      expect(questions[1].multiSelect, isTrue);
    });

    test('malformed payload degrades to empty defaults', () {
      final interaction = PendingInteraction.fromJson({
        'interactionId': 'int_3',
        'kind': 'userInput',
        'payload': {'kind': 'userInput'},
      });
      expect(interaction.prompt, '');
      expect(interaction.options, isEmpty);
      expect(interaction.questions, isEmpty);
      expect(interaction.freeText, isFalse);
    });
  });

  group('buildQuestionAnswerContent', () {
    final questions = [
      PendingInteraction.fromJson({
        'interactionId': 'x',
        'kind': 'userInput',
        'payload': {
          'kind': 'userInput',
          'prompt': '',
          'freeText': false,
          'questions': [
            {
              'question': 'Q1',
              'header': '',
              'options': [
                {'value': 'a', 'label': 'A'},
                {'value': 'b', 'label': 'B'},
              ],
            },
            {
              'question': 'Q2',
              'header': '',
              'multiSelect': true,
              'options': [
                {'value': 'x', 'label': 'X'},
                {'value': 'y', 'label': 'Y'},
              ],
            },
          ],
        },
      }).questions,
    ].first;

    test('matches the web client shape: answers + answer_i (+answer for 1q)',
        () {
      final content = buildQuestionAnswerContent(questions, {
        'Q1': ['a'],
        'Q2': ['x', 'y'],
      });
      expect(content['answers'], {'Q1': 'a', 'Q2': 'x, y'});
      expect(content['answer_0'], 'a');
      expect(content['answer_1'], ['x', 'y']);
      // Two questions: no top-level 'answer'.
      expect(content.containsKey('answer'), isFalse);
    });

    test('single question also fills answer; custom text joins in', () {
      final single = [questions.first];
      final content = buildQuestionAnswerContent(single, {
        'Q1': ['自定义回答'],
      });
      expect(content['answers'], {'Q1': '自定义回答'});
      expect(content['answer_0'], '自定义回答');
      expect(content['answer'], '自定义回答');
    });

    test('unanswered questions are omitted', () {
      final content = buildQuestionAnswerContent(questions, {
        'Q2': ['y'],
      });
      expect(content['answers'], {'Q2': 'y'});
      expect(content.containsKey('answer_0'), isFalse);
      expect(content['answer_1'], ['y']);
    });

    test('blank values are dropped', () {
      final single = [questions.first];
      final content = buildQuestionAnswerContent(single, {
        'Q1': ['  ', ''],
      });
      expect(content['answers'], isEmpty);
      expect(content.containsKey('answer'), isFalse);
    });
  });
}
