#!/bin/sh
# HomeProxy 构建脚本的一键拉取器（POSIX sh，可在 busybox ash 下运行）
#
# 用法（路由器上，任选其一）：
#   1) 直接管道执行本文件（会先把主脚本下载到 /tmp 再运行）：
#        wget -O - https://raw.githubusercontent.com/magickual-5/homeproxy-build/refs/heads/main/get-hp.sh | sh
#      （若 wget 不支持 -O -，可改用： curl -fsSL <上面URL> | sh）
#
#   2) 或两步：先下载主脚本，再运行：
#        wget -O /tmp/homeproxy-build.sh https://raw.githubusercontent.com/magickual-5/homeproxy-build/main/homeproxy-build.sh
#        sh /tmp/homeproxy-build.sh
#
# 说明：主脚本 homeproxy-build.sh 内部会自动用 bash 重跑自身、并用 opkg
# 补齐 bash/jq/curl/openssl/unzip 依赖，因此“拉取后直接运行”即可。

set -e

# ↓↓↓ 部署到 GitHub 后，把下面这行改成你自己的 Raw 地址 ↓↓↓
REPO_RAW="https://raw.githubusercontent.com/magickual-5/homeproxy-build/refs/heads/main"
MAIN="homeproxy-build.sh"
DEST="/tmp/${MAIN}"

if [ -z "$REPO_RAW" ]; then
  echo "请先编辑 get-hp.sh，设置 REPO_RAW。" >&2
  exit 1
fi

if command -v wget >/dev/null 2>&1; then
  wget -O "$DEST" "${REPO_RAW}/${MAIN}"
elif command -v curl >/dev/null 2>&1; then
  curl -fL -o "$DEST" "${REPO_RAW}/${MAIN}"
else
  echo "未找到 wget 或 curl，无法下载主脚本。" >&2
  exit 1
fi

chmod +x "$DEST"
exec sh "$DEST" "$@"
