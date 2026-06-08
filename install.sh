#!/usr/bin/env bash
# Install the Powvm Control plugin into a local PegaProx instance.
# Run as root on the PegaProx host (e.g. LXC 119).
set -euo pipefail

PLUGIN_ID="proxmox-power"
PEGAPROX_DIR="${PEGAPROX_DIR:-/opt/PegaProx}"
PLUGINS_DIR="$PEGAPROX_DIR/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
DB="$PEGAPROX_DIR/config/pegaprox.db"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing $PLUGIN_ID into $DEST"
[ -d "$PEGAPROX_DIR" ] || { echo "PegaProx not found at $PEGAPROX_DIR"; exit 1; }

mkdir -p "$DEST"
for f in __init__.py manifest.json power.html; do
  cp -f "$SRC/$f" "$DEST/$f"
done

# Seed config.json on first install only (never clobber operator config).
if [ ! -f "$DEST/config.json" ]; then
  echo '{ "groups": [] }' > "$DEST/config.json"
fi
chmod 600 "$DEST/config.json"

# Try to enable the plugin in plugin_state — but only if the DB is a *plain*
# SQLite file. Newer PegaProx encrypts the DB via dbcrypto/SQLCipher, where an
# external sqlite3 fails with "file is not a database (26)". In that case (and
# any other), we never touch the DB and just tell the operator to flip the
# toggle in the UI. This step must never abort the install.
ENABLED_VIA_DB=0
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ] \
   && sqlite3 "$DB" "PRAGMA schema_version;" >/dev/null 2>&1; then
  if sqlite3 "$DB" "INSERT OR REPLACE INTO plugin_state (plugin_id, enabled) VALUES ('$PLUGIN_ID', 1);" 2>/dev/null; then
    ENABLED_VIA_DB=1
    echo "==> Enabled in plugin_state (plain SQLite)"
  fi
fi
if [ "$ENABLED_VIA_DB" -eq 0 ]; then
  echo "!! Could not auto-enable via the DB (it is encrypted or locked — normal)."
  echo "   Files are installed. Enable it from the web UI:"
  echo "     PegaProx > Settings > Plugins > 'Powvm Control' > Enable"
fi

# Ownership must match the user the pegaprox *service* runs as (it writes
# config.json at runtime), NOT the owner of $PEGAPROX_DIR (often root). Prefer
# the systemd User=, then the owner of an existing plugin / the plugins dir.
SVC_USER="$(systemctl show -p User --value pegaprox 2>/dev/null)"
if [ -z "$SVC_USER" ] || [ "$SVC_USER" = "root" ]; then
  if [ -d "$PLUGINS_DIR/docker_swarm" ]; then
    SVC_USER="$(stat -c '%U' "$PLUGINS_DIR/docker_swarm")"
  else
    SVC_USER="$(stat -c '%U' "$PLUGINS_DIR" 2>/dev/null || echo pegaprox)"
  fi
fi
SVC_GROUP="$(id -gn "$SVC_USER" 2>/dev/null || echo "$SVC_USER")"
chown -R "$SVC_USER:$SVC_GROUP" "$DEST" 2>/dev/null || true
chmod 775 "$DEST" 2>/dev/null || true
chmod 600 "$DEST/config.json" 2>/dev/null || true
echo "==> Ownership set to $SVC_USER:$SVC_GROUP"

# --- Persistence + auto-update guard (systemd timer) ------------------------
# Cache lives OUTSIDE $PEGAPROX_DIR so it survives a PegaProx reinstall. A timer
# restores the plugin if an upgrade wipes it, and (opt-in) auto-updates it.
CACHE_DIR="${CACHE_DIR:-/usr/local/lib/proxmox-power}"
SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/alfonsokuen/pegaprox-plugin-proxmox-power/main}"
AUTO_UPDATE="${AUTO_UPDATE:-false}"
if command -v systemctl >/dev/null 2>&1; then
  echo "==> Installing persistence/auto-update guard -> $CACHE_DIR"
  mkdir -p "$CACHE_DIR"
  for f in __init__.py manifest.json power.html; do cp -f "$SRC/$f" "$CACHE_DIR/$f"; done
  cp -f "$SRC/pp-maintenance.sh" "$CACHE_DIR/pp-maintenance.sh"
  chmod +x "$CACHE_DIR/pp-maintenance.sh"

  cat > /etc/proxmox-power.conf <<CONF
# Powvm Control — host maintenance config
PEGAPROX_DIR=$PEGAPROX_DIR
CACHE_DIR=$CACHE_DIR
SVC_USER=$SVC_USER
SOURCE=$SOURCE_URL
AUTO_UPDATE=$AUTO_UPDATE
CONF

  cat > /etc/systemd/system/proxmox-power-maintenance.service <<'UNIT'
[Unit]
Description=Powvm Control - persistence + auto-update guard
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/proxmox-power/pp-maintenance.sh
UNIT

  cat > /etc/systemd/system/proxmox-power-maintenance.timer <<'UNIT'
[Unit]
Description=Run Powvm Control maintenance periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now proxmox-power-maintenance.timer >/dev/null 2>&1 \
    && echo "==> Guard timer active (auto_update=$AUTO_UPDATE, source=$SOURCE_URL)" \
    || echo "!! could not enable proxmox-power-maintenance.timer"
else
  echo "!! systemctl not found — skipping persistence guard"
fi

echo "==> Restarting pegaprox"
systemctl restart pegaprox || echo "!! restart manually: systemctl restart pegaprox"
echo "==> Done."
if [ "$ENABLED_VIA_DB" -eq 1 ]; then
  echo "    Open the 'Powvm Control' tab in PegaProx."
else
  echo "    Now enable it: PegaProx > Settings > Plugins > 'Powvm Control' > Enable."
fi
