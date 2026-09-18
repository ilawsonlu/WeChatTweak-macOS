#!/bin/bash

set -euo pipefail

readonly REPOSITORY_URL="${WECHATTWEAK_REPOSITORY_URL:-https://github.com/ilawsonlu/WeChatTweak-macOS.git}"
readonly REPOSITORY_BRANCH="${WECHATTWEAK_REPOSITORY_BRANCH:-master}"
readonly SUPPORTED_BUILD="270098"
readonly SUPPORTED_VERSION="4.1.15.18"

APP_PATH="/Applications/WeChat.app"
ASSUME_YES=0
DRY_RUN=0
LAUNCH_AFTER_INSTALL=1
TEMP_DIR=""

info() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
WeChatTweak 一键安装脚本

用法：
  ./install.sh [选项]

选项：
  --app PATH     指定 WeChat.app 路径（默认：/Applications/WeChat.app）
  --yes, -y      跳过安装确认
  --dry-run      只检查环境、版本和构建，不修改微信
  --no-launch    安装完成后不启动微信
  --help, -h     显示帮助

支持范围：
  Apple Silicon，官网版微信 4.1.15.18（CFBundleVersion 270098）
  功能包括阻止消息撤回和阻止自动更新；不包含多开。
EOF
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || die "--app 后必须提供路径"
      APP_PATH="$2"
      shift 2
      ;;
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1（使用 --help 查看帮助）"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "此脚本只能在 macOS 上运行"
[[ "$(/usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null || printf '0')" == "1" ]] \
  || die "微信 $SUPPORTED_VERSION 的补丁目前只支持 Apple Silicon Mac"

for command_name in swift git codesign open; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "缺少命令 $command_name。请先运行 xcode-select --install 安装 Xcode Command Line Tools。"
done

[[ -d "$APP_PATH" ]] || die "没有找到 $APP_PATH，请先安装官网版微信或使用 --app 指定路径"
readonly INFO_PLIST="$APP_PATH/Contents/Info.plist"
readonly TARGET_BINARY="$APP_PATH/Contents/Resources/wechat.dylib"
[[ -f "$INFO_PLIST" && -f "$TARGET_BINARY" ]] || die "$APP_PATH 不是受支持的微信应用"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
FULL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :WeChatBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
DISPLAY_VERSION="${FULL_VERSION:-$SHORT_VERSION}"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$BUILD_VERSION" == "$SUPPORTED_BUILD" ]] || die \
  "检测到微信 ${DISPLAY_VERSION:-未知版本}（构建 ${BUILD_VERSION:-未知}），本脚本仅支持 $SUPPORTED_VERSION（构建 $SUPPORTED_BUILD）"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [[ -f "$SCRIPT_DIR/Package.swift" && -f "$SCRIPT_DIR/config.json" ]]; then
  SOURCE_ROOT="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../Package.swift" && -f "$SCRIPT_DIR/../config.json" ]]; then
  SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  info "下载 WeChatTweak 源码"
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wechattweak-install.XXXXXX")"
  git clone --quiet --depth 1 --branch "$REPOSITORY_BRANCH" "$REPOSITORY_URL" "$TEMP_DIR/source"
  SOURCE_ROOT="$TEMP_DIR/source"
fi

readonly SOURCE_ROOT
readonly CONFIG_PATH="$SOURCE_ROOT/config.json"

info "检查安装目标"
printf '微信路径：%s\n' "$APP_PATH"
printf '微信版本：%s（构建 %s）\n' "$DISPLAY_VERSION" "$BUILD_VERSION"
printf '源码路径：%s\n' "$SOURCE_ROOT"

info "构建 WeChatTweak"
swift build --package-path "$SOURCE_ROOT" -c release
BIN_DIR="$(swift build --package-path "$SOURCE_ROOT" -c release --show-bin-path)"
PATCHER="$BIN_DIR/wechattweak"
[[ -x "$PATCHER" ]] || die "构建完成，但没有找到 wechattweak 可执行文件"

info "验证版本配置"
VERSIONS_OUTPUT="$("$PATCHER" versions --app "$APP_PATH" --config "$CONFIG_PATH")"
printf '%s\n' "$VERSIONS_OUTPUT"
printf '%s\n' "$VERSIONS_OUTPUT" | awk -v expected="$SUPPORTED_BUILD" '
  $0 == "------ Supported versions ------" { in_supported = 1; next }
  in_supported && $0 == expected { found = 1 }
  END { exit(found ? 0 : 1) }
' \
  || die "本地 config.json 不包含构建 $SUPPORTED_BUILD"

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "检查完成（dry-run），没有修改微信"
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  [[ -r /dev/tty ]] || die "当前环境无法交互确认；请检查脚本后使用 --yes 重试"
  printf '\n将修改 %s，并创建版本化备份。继续？[y/N] ' "$TARGET_BINARY" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "用户取消安装" ;;
  esac
fi

wechat_processes() {
  ps -axo pid=,command= \
    | APP_SCAN_PREFIX="$APP_PATH/Contents/MacOS/" awk 'index($0, ENVIRON["APP_SCAN_PREFIX"]) { print $1 }'
}

if [[ -n "$(wechat_processes)" ]]; then
  info "正在安全退出微信"
  /usr/bin/osascript -e 'tell application id "com.tencent.xinWeChat" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    [[ -z "$(wechat_processes)" ]] && break
    sleep 1
  done
  [[ -z "$(wechat_processes)" ]] || die "微信仍在运行。请手动完全退出微信后重试；脚本不会强制结束进程。"
fi

info "应用补丁并重新签名"
PATCH_COMMAND=("$PATCHER" patch --app "$APP_PATH" --config "$CONFIG_PATH")
if [[ ! -w "$APP_PATH" || ! -w "$TARGET_BINARY" ]]; then
  command -v sudo >/dev/null 2>&1 || die "没有权限修改微信，且系统中找不到 sudo"
  warn "微信由其他用户或系统拥有，只会为补丁命令请求管理员权限。"
  PATCH_COMMAND=(sudo "${PATCH_COMMAND[@]}")
fi
"${PATCH_COMMAND[@]}"

info "验证应用签名"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
  info "启动微信"
  /usr/bin/open "$APP_PATH"
  for _ in {1..10}; do
    [[ -n "$(wechat_processes)" ]] && break
    sleep 1
  done
  [[ -n "$(wechat_processes)" ]] || die "补丁和签名均已完成，但微信没有在 10 秒内启动。请手动打开并检查系统提示。"
fi

info "安装完成"
printf '已启用：阻止消息撤回、阻止自动更新\n'
printf '备份位置：%s.%s.bak\n' "$TARGET_BINARY" "$SUPPORTED_BUILD"
if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
  printf '微信已启动，请使用另一个账号进行一次实际撤回测试。\n'
fi
