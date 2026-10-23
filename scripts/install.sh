#!/usr/bin/env bash
# Prepara um container Debian 12 para uma app: Node 22, utilizador e pastas, chave de deploy (só leitura),
# .env, serviço systemd, deploy automático (de 5 em 5 min), Tailscale com HTTPS e backup para o Google Drive.
# Pode correr-se outra vez: só cria o que falta.
#
# Uso (como root, dentro do container): /opt/homelab/scripts/install.sh /opt/homelab/apps/<app>.conf
set -euo pipefail

CONF=$(readlink -f "${1:?Uso: install.sh <app>.conf}")
# shellcheck source=/dev/null
source "$CONF"
HOMELAB=$(dirname "$(dirname "$(readlink -f "$0")")")
BASE=/srv/$APP
passo() { echo; echo "==> $*"; }

passo "Pacotes base"
apt-get update -qq
# unzip: o instalador do rclone precisa dele
apt-get install -y -qq git curl ca-certificates openssl openssh-client unzip >/dev/null

if ! command -v node >/dev/null || [[ $(node -v) != v22* ]]; then
  passo "Node 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
echo "node $(node -v)"

# O router/ISP dá DNS em 100.64.0.0/10, a mesma gama do Tailscale: com o Tailscale ligado, as perguntas
# de DNS iam pelo túnel e perdiam-se (sem DNS não há deploy nem certificado HTTPS). Fixa DNS públicos.
if [[ -f /etc/dhcp/dhclient.conf ]] && ! grep -q 'supersede domain-name-servers' /etc/dhcp/dhclient.conf; then
  passo "DNS fixos (1.1.1.1, 9.9.9.9)"
  echo 'supersede domain-name-servers 1.1.1.1, 9.9.9.9;' >> /etc/dhcp/dhclient.conf
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf
fi

passo "Utilizador e pastas ($BASE)"
id "$APP" &>/dev/null || useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin "$APP"
mkdir -p "$BASE"/{releases,shared,data} "$BACKUP_DIR"
chown -R "$APP:$APP" "$BASE" "$BACKUP_DIR"

if [[ ! -f $BASE/shared/deploy_key ]]; then
  passo "Chave de deploy"
  runuser -u "$APP" -- ssh-keygen -q -t ed25519 -N '' -C "$APP@$(hostname)" -f "$BASE/shared/deploy_key"
fi

if [[ ! -f $BASE/shared/.env ]]; then
  passo "Configuração (.env)"
  criar_env > "$BASE/shared/.env"
  chown "$APP:$APP" "$BASE/shared/.env"
  chmod 600 "$BASE/shared/.env"
fi

passo "Serviços systemd"
cat > "/etc/systemd/system/$APP.service" <<EOF
[Unit]
Description=$APP
After=network-online.target
Wants=network-online.target

[Service]
User=$APP
WorkingDirectory=$BASE/current
ExecStart=$START_CMD
Environment=NODE_ENV=production
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "/etc/systemd/system/$APP-deploy.service" <<EOF
[Unit]
Description=Publica a versão nova de $APP (se houver)
After=network-online.target

[Service]
Type=oneshot
ExecStart=$HOMELAB/scripts/deploy.sh $CONF
EOF

cat > "/etc/systemd/system/$APP-deploy.timer" <<EOF
[Unit]
Description=Procura versões novas de $APP de 5 em 5 minutos

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

cat > "/etc/systemd/system/$APP-backup.service" <<EOF
[Unit]
Description=Copia os backups de $APP para $RCLONE_DEST
After=network-online.target
ConditionPathExists=/root/.config/rclone/rclone.conf

[Service]
Type=oneshot
ExecStart=/usr/bin/rclone copy $BACKUP_DIR $RCLONE_DEST
EOF

cat > "/etc/systemd/system/$APP-backup.timer" <<EOF
[Unit]
Description=Backup de $APP para o Google Drive de 6 em 6 horas

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable "$APP.service" "$APP-deploy.timer" "$APP-backup.timer" >/dev/null

if ! command -v tailscale >/dev/null; then
  passo "Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi
if ! command -v rclone >/dev/null; then
  passo "rclone"
  curl -fsSL https://rclone.org/install.sh | bash >/dev/null
fi

passo "Falta (passos manuais — ver docs/proxmox.md)"
echo "1. Adicionar esta chave em GitHub → $REPO → Settings → Deploy keys (só leitura):"
echo
cat "$BASE/shared/deploy_key.pub"
echo
echo "2. Primeiro deploy:   $HOMELAB/scripts/deploy.sh $CONF --forcar && systemctl start $APP-deploy.timer"
echo "3. Tailscale:         tailscale up --hostname=$APP --accept-dns=false && tailscale serve --bg $PORT"
echo "4. Google Drive:      rclone config  (remote \"gdrive\"; ver docs) && systemctl start $APP-backup.timer"
