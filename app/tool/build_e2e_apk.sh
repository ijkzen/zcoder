#!/bin/bash
# 真机 E2E 用的快速 release 构建：只编 arm64（省多 ABI 编译时间），
# 产物 app-release.apk。与正式交付同样启用 R8 收缩 + release-key.jks
# 签名（key.properties 缺失时回退 debug 签名），包形态最接近发布版。
# 默认开启 ZREMOTE_LOG：zlog 日志同时进入 app 内协议日志页和 LogCat
# （logcat tag 为 flutter，行前缀 [zremote]），方便真机现场排查。
set -euo pipefail
cd "$(dirname "$0")/.."
exec flutter build apk --release --target-platform android-arm64 \
  -PabiFilter=arm64-v8a --dart-define=ZREMOTE_LOG=true
