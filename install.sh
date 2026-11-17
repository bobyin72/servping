#!/bin/sh
# ============================================================================
# ServPing 安装脚本
# ----------------------------------------------------------------------------
#   ./install.sh                    装到 /usr/local/bin（需要写权限）
#   ./install.sh --prefix ~/.local  装到 ~/.local/bin
#   ./install.sh --with-config      同时装一份样例配置（不覆盖已有配置）
# ============================================================================
set -eu

PREFIX="/usr/local"
WITH_CONF=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)      PREFIX="${2:?--prefix 需要一个目录}"; shift 2 ;;
        --with-config) WITH_CONF=1; shift ;;
        -h|--help)     sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             printf '未知参数: %s（-h 看用法）\n' "$1" >&2; exit 2 ;;
    esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/ServPing"
[ -f "$SRC" ] || { printf '找不到 %s\n' "$SRC" >&2; exit 2; }

DEST_DIR="$PREFIX/bin"
DEST="$DEST_DIR/ServPing"

mkdir -p "$DEST_DIR"
if [ -w "$DEST_DIR" ]; then
    install -m 755 "$SRC" "$DEST"
else
    printf '需要写权限: %s\n' "$DEST_DIR" >&2
    printf '试试: sudo ./install.sh\n' >&2
    exit 1
fi
printf '已安装: %s\n' "$DEST"

if [ "$WITH_CONF" = "1" ]; then
    CONF_DIR="$PREFIX/etc"
    CONF="$CONF_DIR/servping.conf"
    mkdir -p "$CONF_DIR"
    if [ -e "$CONF" ]; then
        printf '配置已存在，未覆盖: %s\n' "$CONF"
    else
        install -m 644 "$HERE/servping.conf.example" "$CONF"
        printf '已安装样例配置: %s\n' "$CONF"
    fi
fi

# 自检：装完能跑起来才算完
if "$DEST" -V >/dev/null 2>&1; then
    printf '自检通过: %s\n' "$("$DEST" -V)"
else
    printf '装上了但跑不起来，请检查 bash 版本\n' >&2
    exit 1
fi
