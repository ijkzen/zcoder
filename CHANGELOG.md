# Changelog / 更新日志

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的格式，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

格式：`版本号 - 日期`（YYYY-MM-DD）。更早的细节见 git 历史。

## [Unreleased]

- （待定 / TBD）

## [0.4.5+12] - 2026-08-18

### 新增 / Added

- 会话列表状态圆点颜色映射——绿色已完成/蓝色进行中/红色错误/黄色草稿/其他无圆点。
- 会话列表页右上角新增更多菜单，模型配置入口移入其中。
- 更新提示改为弹窗展示——检查到新版本时弹出 AlertDialog 显示 releaseNotes，点取消关闭或点更新走下载安装流程。

### 修复 / Fixed

- 重连成功后自动清除断线通知。
- 从项目列表返回后设备项卡在「等待桌面端…」无法再进入。

## [0.4.1+8] - 2026-08-17

首个公开发布版本（仓库初始化即为此版本，全部历史见 git log）。

### 新增 / Added

- 协议层重构：`docs/protocol/` 权威文档 + `app/lib/src/protocol/` 五层模块（relay / bridge / session / topics / services），分片 512KiB 修正、relay 出站排队、KICKED 处理、bridge 恢复循环、V4 服务封装与附件读取、mergedEntries 多任务保留。
- 排队消息（held queue）全量落地：数据 / 命令 / UI / 测试；修复推送根因（`requestEvent` 事件监听参数多包一层列表导致帧路由不到），真机验证排队消息实时到达。
- 四类本地通知（需要批准 / 任务完成 / 出错停滞 / 断线告警）+ 前台服务常驻 + deep link 直达会话。
- 会话/项目列表下拉刷新（RefreshIndicator）；用户消息中的技能调用渲染为徽章（`$name` → ✨ 技能名）。
- 审批/提问卡片标记子智能体来源；审批弹窗命令详情族感知展示（执行/文件改动/读取/搜索/JSON 兜底）+ 共享 MonoText 组件。
- 屏幕常亮、附件上传重试、消息操作与模式 chips、日志页、提供商管理、任务标签搜索未读置顶。
- UI 测试用例文档 v1.1（`docs/ui-test-cases.md`，约 127 用例）。

### 修复 / Fixed

- 会话模型弹窗协作模式误显 workspace 共享值（`conversationPickerConfig` 漏传会话级 `mode`）。
- 模型弹窗残留已删除的 Provider（桌面 runtime 不重建 `settings.model.available`）。
- stale pair 强制重连、`sessionId` nullable envelope、RelayFailure/reconnect 响应扩展、并发连接防护。
- 平均缓存命中率改用会话快照 `usage.contextWindow.cache.hitRate`，去掉 `getTaskTokenUsage` 累计兜底。
- 编辑重发仅限最后一条用户消息；打断按钮显示条件与工作状态行按 `session.status` 权威信号判断。

### 变更 / Changed

- 压缩会话入口迁至输入栏 `/compact` 斜杠命令（移动端删除 UI 入口，由桌面端处理）。
- 待办面板数据源切到会话快照 `plan` + `readSession` todos（含驼峰/下划线归一化）。
- 打断按钮从输入栏移入会话右上角菜单；弹窗间距统一收紧（主题级 `dialogTheme`）。
- 构建提速：Gradle 并行 + 任务输出缓存 + E2E 快速构建脚本，release 增量 65s→14s、APK 71MB→34MB。

[Unreleased]: https://github.com/ijkzen/zcoder/compare/v0.4.1+8...master
[0.4.1+8]: https://github.com/ijkzen/zcoder/releases/tag/v0.4.1+8
