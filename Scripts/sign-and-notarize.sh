#!/usr/bin/env bash
# sign-and-notarize.sh — 发布构建：签名 + 公证（文档 §47：Helper signing / Hardened Runtime / Notarization）
#
# 前置条件（发布机器上）：
#   - Developer ID Application 证书 + Developer ID Installer（或 Development 证书做内部分发）
#   - 环境变量：APPLE_ID / APPLE_TEAM_ID / APPLE_PASSWORD（App 专用密码）或 notarytool keychain profile
#
# 用法：
#   ./Scripts/sign-and-notarize.sh            # 对 build/Release 产物签名并公证
#
# 说明：
#   - 主 App 与 RuntimeHelper.xpc 必须用**同一 Developer ID** 签名（XPC 同 team 要求，
#     见 ARCHITECTURE.md ADR-007）；Helper 通过 Copy Files 的 CodeSignOnCopy 随 App 一起签名；
#   - ENABLE_HARDENED_RUNTIME = YES 已在工程中启用（App + Helper）；
#   - 本脚本是发布流水线参考，实际执行需在持有证书与凭据的 CI / 发布机上运行。
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="build/ReleaseDerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/DeepSeek Harness.app"
IDENTITY="${IDENTITY:-Developer ID Application}"

echo "== 1. Release 构建（含 fetch-node-runtime） =="
# 先准备 App-owned Node Runtime（文档 §10）
./Scripts/fetch-node-runtime.sh --all
xcodebuild -project 'DeepSeek Harness.xcodeproj' -scheme 'DeepSeek Harness' \
  -configuration "${CONFIGURATION}" -derivedDataPath "${DERIVED_DATA}" \
  -destination 'platform=macOS' build

echo "== 2. 校验 Helper 已嵌入 =="
test -d "${APP_PATH}/Contents/XPCServices/RuntimeHelper.xpc"

echo "== 3. 公证（notarytool） =="
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_PASSWORD:-}" ]]; then
  ditto -c -k --keepParent "${APP_PATH}" "/tmp/DeepSeek Harness.zip"
  xcrun notarytool submit "/tmp/DeepSeek Harness.zip" \
    --apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" --password "${APPLE_PASSWORD}" \
    --wait
  xcrun stapler staple "${APP_PATH}"
  echo "✔ 公证并装订完成"
else
  echo "⚠ 未提供公证凭据，跳过公证（本地签名产物可用于开发测试）"
fi

echo "完成：${APP_PATH}"
