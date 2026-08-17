#!/bin/bash
# 真机 E2E 用的快速 debug 构建：只编 arm64（省 AOT 多 ABI，包体更小）。
# Debug 包带符号、不收缩，安装快、方便现场排查；正式交付仍用
# `flutter build apk --release`（完整收缩 + 全 ABI）。
# 额外参数原样透传，例如: tool/build_e2e_apk.sh --dart-define=KEY=VALUE
set -euo pipefail
cd "$(dirname "$0")/.."
exec flutter build apk --debug --target-platform android-arm64 "$@"
