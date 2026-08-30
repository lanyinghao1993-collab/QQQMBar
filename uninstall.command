#!/bin/zsh
set -euo pipefail

DESTINATION="$HOME/Applications/QQQMBar.app"
if [[ ! -e "$DESTINATION" ]]; then
  echo "没有找到已安装的 QQQMBar。"
  exit 0
fi

pkill -x QQQMBar 2>/dev/null || true
TRASH_TARGET="$HOME/.Trash/QQQMBar-$(date +%Y%m%d-%H%M%S).app"
mv "$DESTINATION" "$TRASH_TARGET"
echo "已移至废纸篓：$TRASH_TARGET"
echo "本地数据未删除：~/Library/Application Support/QQQMBar"
