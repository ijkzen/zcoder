# ZCode 远程（Flutter）

用 Flutter 重写的 ZCode 远程控制客户端——替代官方 Web 远程控制页面（`https://zcode.z.ai/remote/v4`）。Android 原生 Material 3 应用。

## 解决的问题

| 网页版痛点 | 本应用对策 |
|---|---|
| 断线重连体验差 | 前台服务常驻 + 心跳 10s + 指数退避自动重连（与桌面端同参数） |
| 缺推送通知 | 四类通知：需要批准 / 任务完成 / 出错停滞 / 断线告警，点击直达会话 |
| 性能卡顿 | 原生渲染 + 流式增量（row.delta）+ 本地纯文本缓存 |
| 界面复杂/输入不便 | 设备→工作区→会话三层导航 + reasoning 默认折叠 + 底部大输入区带打断按钮 |

## 使用

1. 桌面端 ZCode 打开「Web 远程控制」，手机端点「扫码配对」扫描二维码
2. 设备列表点选电脑 → 连接 → 选择工作区 → 会话列表 → 进入会话
3. 会话内：底部输入框发消息、打断按钮、批准卡片内联处理权限请求

## 构建

```bash
# 国内镜像环境变量（macOS）
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
export ANDROID_HOME="$HOME/Library/Android/sdk"

flutter pub get
flutter test          # 协议层单元测试
flutter build apk     # release APK（output: build/app/outputs/flutter-apk/app-release.apk）
```

## 架构

```
lib/
├── main.dart                    # 入口（AppController + 通知服务初始化）
└── src/
    ├── relay/                   # 中继 WebSocket：sid+hash 认证、心跳、重连
    │   ├── relay_types.dart     #   帧类型 / 凭据解析（QR URL）
    │   └── relay_client.dart    #   连接状态机（HMAC proof 认证）
    ├── bridge/                  # 工作区桥接
    │   ├── acknowledged_protocol.dart  # rpc-frame 分片/CRC32/ack
    │   ├── binary_rpc.dart             # 13 字节头帧 + 类型化序列化 + ChannelClient
    │   └── bridge_manager.dart         # 配对→bridge-open→会话通道编排
    ├── session/                 # 主题订阅协议
    │   ├── models.dart          #   工作区/会话/对话行（snapshot & deltas）
    │   ├── session_channel.dart #   hello/subscribe/命令（zcode-session 频道）
    │   ├── conversation_controller.dart  # 会话流状态机
    │   └── sessions_index_controller.dart
    ├── storage/app_database.dart  # sqflite：配对 + 会话纯文本缓存
    ├── services/notifications.dart # 本地通知 + 前台服务
    └── ui/                      # 四屏：设备 / 工作区 / 会话 / 会话流
```

## 协议要点（逆向自 app.asar 与 Web bundle）

- 中继：`wss://zcode.z.ai/ws?mid=<deviceMid>`，终端认证 = `auth_init(role:"terminal")` → challenge → `HMAC-SHA256(passHash, "$sid|$nonce|terminal")` base64url
- 应用载荷：`zcode_type` + `requestId` 判别联合（workspace-list / workspace-bridge-open / rpc-frame …）
- rpc-frame：1MB 物理帧、16MB 消息、64 分片、CRC32 校验、`rpc-frame-ack` 确认
- 二进制 RPC：13 字节头 `[type:u8][id:u32BE][ack:u32BE][len:u32BE]`，body = 类型化序列化（1 字节 tag + LEB128 varint），桌面端先发 Initialize(200)
- 主题订阅：`helloConversationV4` / `initializeConversationV4` → `subscribeConversationV4`，快照 + 增量（`row.delta` 流式追加）
- 命令：`sendConversationCommandV4`（sendText / stop / resolveInteraction / createSession …）

详见 `docs/adr/0001-sid-hash-terminal-auth.md` 与 `CONTEXT.md`。
