# Contributing / 贡献指南

感谢你有兴趣为 **ZCode 远程（Flutter）** 做贡献！无论是提 issue、改代码、补文档都欢迎。在动手之前请先阅读本指南与 [`CONTEXT.md`](CONTEXT.md)（领域术语表）。

Thanks for your interest in contributing to **ZCode Remote (Flutter)**! Issues, code, and docs are all welcome. Please read this guide and the [`CONTEXT.md`](CONTEXT.md) glossary before you start.

## 项目结构 / Project layout

```
app/                            # Flutter 应用（入口 app/lib/main.dart）
  lib/src/protocol/             # 协议层：relay / bridge / session / topics / services
  lib/src/storage/              # sqflite 本地缓存（配对 + 会话纯文本）
  lib/src/services/             # 通知与前台服务
  lib/src/ui/                   # 四屏 UI：设备 / 工作区 / 会话 / 会话流
  test/                         # 协议与行为单元测试
  tool/build_e2e_apk.sh         # E2E 快速构建脚本（debug key、arm64、无 shrink）
docs/
  adr/                          # 架构决策记录（英文）
  protocol/                     # 协议文档（英文，逆向自 app.asar 与 Web bundle）
  ui-test-cases.md              # UI 测试用例文档（中文）
CONTEXT.md                      # 领域术语表（英文）
```

## 开发环境 / Development environment

国内镜像环境变量（macOS）：

```bash
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
export ANDROID_HOME="$HOME/Library/Android/sdk"
```

## 常用命令 / Common commands

```bash
cd app
flutter pub get     # 拉取依赖
flutter analyze     # 静态检查（提交前必须通过）
flutter test        # 单元测试（协议层/行为，提交前必须通过）
flutter build apk   # release APK
./tool/build_e2e_apk.sh   # 快速 E2E 包（覆盖安装到真机联调）
```

> 协议改动或连接流程改动后，建议在真机做一次 E2E 验证（设备列表 → 连接 → 进入会话），并在 PR 描述里注明。

## 代码与文档规范 / Code & docs conventions

- 术语一律遵循 [`CONTEXT.md`](CONTEXT.md)（Device / Relay / Terminal / Workspace / Session / Row …，有明确禁用词）。
- 文档语言约定：
  - `docs/protocol/`、`docs/adr/`：英文；
  - `docs/ui-test-cases.md`、`README.md`：中文；
  - 协议文档与 ADR 记录**事实**（含被推翻的旧结论），改动时同步更新。
- UI 改动需要同步 `docs/ui-test-cases.md` 中对应用例与编号（参见文件内编号约定）。

## 提交信息规范 / Commit message convention

格式：`<类型>：<中文描述>`，一段话说明“改了什么、为什么”，必要时在括号里补充关键细节。

常见类型（参考历史提交）：

| 类型 | 含义 |
|---|---|
| 协议 / 协议与队列 / 协议与核心 | 协议层、连接、队列 |
| UI / UI/数据 / 会话与列表 UI | 界面与交互 |
| 修复 | bug 修复 |
| 功能优化与修复 | 功能 + 修复混合 |
| 测试与文档 / 文档 / docs | 测试用例、文档、ADR |
| 构建 | 构建脚本、Gradle、CI |
| 初始提交 | 仓库初始化 |

示例：

```
修复：会话模型弹窗协作模式误显 workspace 共享值（conversationPickerConfig 重建配置时漏传会话级 mode）
UI：项目/会话列表支持下拉刷新（RefreshIndicator）
docs：ui-test-cases 同步三项变更的用例与编号
```

## 提 PR 流程 / Pull request workflow

1. 从 `master` 切分支：`git checkout -b feat/xxx`（或 `fix/xxx`）。
2. 完成改动，确保 `flutter analyze` 与 `flutter test` 通过。
3. 按上述规范提交，PR 描述里勾选：

   - [ ] `flutter analyze` 通过
   - [ ] `flutter test` 通过
   - [ ] UI 改动已同步 `docs/ui-test-cases.md` 用例与编号
   - [ ] 协议改动已同步 `docs/protocol/` 对应文档（英文）
   - [ ] 术语遵循 `CONTEXT.md`
   - [ ] 行为变化已更新 `CHANGELOG.md`

## 行为准则 / Code of conduct

请阅读并遵守 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)。有问题先搜已有 issue，提问时附上环境信息（机型、系统版本、应用版本、桌面端版本）与相关日志。
