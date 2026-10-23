#!/usr/bin/env bash
# Publica a última versão do branch, se for nova: clona, instala, compila e testa numa pasta à parte;
# só se tudo passar troca o link "current" e reinicia o serviço. Se não arrancar, volta à anterior.
#
# Uso: deploy.sh /opt/homelab/apps/<app>.conf [--forcar]
# Corre como root (pelo timer <app>-deploy.timer); os passos de git/npm correm como o utilizador da app.
set -euo pipefail

CONF=${1:?Uso: deploy.sh <app>.conf [--forcar]}
FORCAR=${2:-}
# shellcheck source=/dev/null
source "$CONF"

BASE=/srv/$APP
RELEASES=$BASE/releases
SHARED=$BASE/shared
MANTER=3
export GIT_SSH_COMMAND="ssh -i $SHARED/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

log() { echo "[$APP] $*"; }
como_app() { runuser -u "$APP" -- env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" HOME="$BASE" bash -c "$1"; }

# Um deploy de cada vez
exec 9>"$BASE/.deploy.lock"
flock -n 9 || { log "já há um deploy a correr"; exit 0; }

remoto=$(como_app "git ls-remote '$REPO' 'refs/heads/$BRANCH'" | cut -f1)
[[ -n $remoto ]] || { log "não consegui ler $BRANCH em $REPO"; exit 1; }
atual=$(basename "$(readlink -f "$BASE/current" 2>/dev/null || echo nenhuma)")

if [[ $remoto == "$atual" && $FORCAR != --forcar ]]; then exit 0; fi
# Uma versão que já falhou não se tenta de 5 em 5 minutos (só com --forcar)
if [[ -f $BASE/.falhou && $(cat "$BASE/.falhou") == "$remoto" && $FORCAR != --forcar ]]; then exit 0; fi

log "nova versão ${remoto:0:7} (atual: ${atual:0:7})"
dest=$RELEASES/$remoto
tmp=$dest.tmp
rm -rf "$tmp"

falhou() {
  log "FALHOU: $1 — continua a correr ${atual:0:7}"
  echo "$remoto" > "$BASE/.falhou"
  rm -rf "$tmp"
  exit 1
}

como_app "git clone --quiet --depth 1 --branch '$BRANCH' '$REPO' '$tmp'" || falhou "git clone"
[[ $(como_app "git -C '$tmp' rev-parse HEAD") == "$remoto" ]] || falhou "o branch mudou durante o clone"
ln -s "$SHARED/.env" "$tmp/.env"
como_app "cd '$tmp' && $BUILD_CMD" || falhou "build"
como_app "cd '$tmp' && $TEST_CMD" || falhou "testes"

rm -rf "$dest"
mv "$tmp" "$dest"
anterior=$(readlink -f "$BASE/current" 2>/dev/null || true)
ln -sfn "$dest" "$BASE/current.novo" && mv -T "$BASE/current.novo" "$BASE/current"
systemctl restart "$APP"

# Confirma que arrancou; se não, volta à versão anterior
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT$HEALTH_PATH"; then
    rm -f "$BASE/.falhou"
    log "publicada ${remoto:0:7}"
    # Limpa versões antigas (fica a atual e as anteriores mais recentes)
    ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +$((MANTER + 1)) | xargs -r rm -rf
    exit 0
  fi
  sleep 1
done

if [[ -n $anterior && -d $anterior ]]; then
  ln -sfn "$anterior" "$BASE/current.novo" && mv -T "$BASE/current.novo" "$BASE/current"
  systemctl restart "$APP"
  falhou "não respondeu em $HEALTH_PATH — reposta $(basename "$anterior" | cut -c1-7)"
fi
falhou "não respondeu em $HEALTH_PATH (não havia versão anterior)"
