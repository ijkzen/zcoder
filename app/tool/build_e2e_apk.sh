#!/bin/bash
# 真机 E2E 用的快速 release 构建：跳过 R8 压缩（省 ~23s）、只编 arm64（省 AOT 多 ABI，包体 ~1/3）。
# 实测从 ~65s 降到 ~20s。正式交付仍用 `flutter build apk --release`（完整收缩 + 全 ABI）。
# 额外参数原样透传，例如: tool/build_e2e_apk.sh --dart-define=KEY=VALUE
set -euo pipefail
cd "$(dirname "$0")/.."
exec flutter build apk --release --no-shrink --target-platform android-arm64 "$@"
