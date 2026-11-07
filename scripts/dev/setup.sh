#!/usr/bin/env bash
# map 开发环境一键初始化脚本
#
# 在项目根目录执行：
#   bash scripts/dev/setup.sh
#
# 作用：
#   1) 打印 flutter 工具链版本
#   2) flutter create 生成 Android 工程骨架（不会覆盖已有 docs/ lib/core/ test/core/）
#   3) flutter pub add 添加设计文档所需依赖
#   4) 保存最终 pubspec.yaml 快照到 logs/pubspec.snapshot.yaml
#   5) 运行纯逻辑核心单测（test/core）
#
# 全部输出写入 logs/setup.log，方便回传排查。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

mkdir -p logs
LOG="$ROOT/logs/setup.log"

echo "=== [1/5] flutter version ===" | tee "$LOG"
flutter --version 2>&1 | tee -a "$LOG" || { echo "flutter 不可用，请先配置 PATH" | tee -a "$LOG"; exit 1; }

echo "=== [2/5] flutter create (project map, platform android) ===" | tee -a "$LOG"
flutter create --project-name map --platforms android . 2>&1 | tee -a "$LOG"

echo "=== [3/5] flutter pub add dependencies ===" | tee -a "$LOG"
flutter pub add \
  flutter_map \
  latlong2 \
  sqflite \
  path_provider \
  geolocator \
  flutter_riverpod \
  path \
  2>&1 | tee -a "$LOG"

echo "=== [4/5] save pubspec snapshot ===" | tee -a "$LOG"
cp pubspec.yaml logs/pubspec.snapshot.yaml 2>&1 | tee -a "$LOG"

echo "=== [5/5] flutter test test/core ===" | tee -a "$LOG"
flutter test test/core 2>&1 | tee -a "$LOG"

echo "=== SETUP DONE (see logs/setup.log) ===" | tee -a "$LOG"
