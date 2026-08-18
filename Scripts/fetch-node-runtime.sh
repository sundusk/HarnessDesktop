#!/usr/bin/env bash
# fetch-node-runtime.sh — Release 构建时下载 App-owned Node Runtime（文档 §7.3 / §10）
#
# 用法：
#   ./Scripts/fetch-node-runtime.sh            # 下载当前架构
#   ./Scripts/fetch-node-runtime.sh --all      # 下载 arm64 + x64
#
# 输出：
#   DeepSeek Harness/Resources/Runtime/node/<arch>/bin/node ...
#   （该目录已 gitignore；Release 打包时随 App 携带，不修改系统 Node）
#
# 来源：Node.js 官方发布 tarball（https://nodejs.org/dist/），仅 HTTPS。
# 默认版本 v22 LTS；可用 NODE_VERSION 环境变量覆盖。
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-v22.14.0}"
OUT_DIR="DeepSeek Harness/Resources/Runtime/node"
BASE_URL="https://nodejs.org/dist/${NODE_VERSION}"

download_arch() {
  local arch="$1"
  local dest="${OUT_DIR}/${arch}"
  if [[ -x "${dest}/bin/node" ]]; then
    echo "✔ ${arch}: Node ${NODE_VERSION} 已存在，跳过"
    return 0
  fi
  echo "↓ ${arch}: 下载 Node ${NODE_VERSION} …"
  local tarball="node-${NODE_VERSION}-darwin-${arch}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL --max-time 300 -o "${tmp}/${tarball}" "${BASE_URL}/${tarball}"
  tar -xzf "${tmp}/${tarball}" -C "${tmp}"
  mkdir -p "${dest}"
  cp -R "${tmp}/node-${NODE_VERSION}-darwin-${arch}/" "${dest}/"
  rm -rf "${tmp}"
  # 保留可执行位，移除符号链接中的绝对路径问题（bin 内是相对链接，无需处理）
  chmod +x "${dest}/bin/node" "${dest}/bin/npm" "${dest}/bin/npx" 2>/dev/null || true
  echo "✔ ${arch}: 就绪 → ${dest}/bin/node"
}

if [[ "${1:-}" == "--all" ]]; then
  download_arch arm64
  download_arch x64
else
  case "$(uname -m)" in
    arm64) download_arch arm64 ;;
    x86_64) download_arch x64 ;;
    *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
  esac
fi
echo "完成。请把 ${OUT_DIR} 加入 App target 的 Resources（Release 打包时）。"
