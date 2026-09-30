#!/usr/bin/env bash
# pnk-node — remote bootstrap
# bash <(curl -fsSL https://raw.githubusercontent.com/pink1ep1e/pnk-node/refs/heads/main/install.sh)
set -euo pipefail

PNK_NODE_RAW="${PNK_NODE_RAW:-https://raw.githubusercontent.com/pink1ep1e/pnk-node/refs/heads/main}"
DEST="${PNK_NODE_DEST:-/opt/pnk-node-suite}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Нужен root — перезапуск через sudo..."
  exec curl -fsSL "${PNK_NODE_RAW%/}/install.sh" | sudo env PNK_NODE_RAW="$PNK_NODE_RAW" PNK_NODE_DEST="$DEST" bash
fi

mkdir -p "$DEST/lib"
BASE="${PNK_NODE_RAW%/}"
for f in menu.sh setup-pnknode.sh remove-pnknode.sh security-setup.sh \
         setup-selfsteal.sh setup-bbr.sh setup-warp.sh \
         lib/ui.sh lib/common.sh; do
  echo "↓ $f"
  curl -fsSL "$BASE/$f" -o "$DEST/$f"
done
chmod +x "$DEST"/*.sh

# persist raw base for peer scripts
if grep -q '^PNK_NODE_RAW=' "$DEST/lib/common.sh" 2>/dev/null; then
  sed -i "s|^PNK_NODE_RAW=.*|PNK_NODE_RAW=\"${BASE}\"|" "$DEST/lib/common.sh" 2>/dev/null || true
fi
# export for this session / symlink wrapper
cat > /usr/local/bin/pnk-node <<EOF
#!/usr/bin/env bash
export PNK_NODE_RAW="${BASE}"
exec bash "${DEST}/menu.sh" "\$@"
EOF
chmod +x /usr/local/bin/pnk-node

echo
echo "Установлено в $DEST"
echo "Запуск:  pnk-node"
echo
exec bash "$DEST/menu.sh"
