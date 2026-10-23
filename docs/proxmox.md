# Pôr uma app a correr no Proxmox

Cada app tem o seu container LXC (Debian 12), acessível só pela tailnet em
`https://<app>.<tailnet>.ts.net`. O container vai buscar sozinho as versões novas do GitHub
(de 5 em 5 minutos) e copia os backups para o Google Drive (de 6 em 6 horas).

Exemplo: `financas` (configuração em [apps/financas.conf](../apps/financas.conf)).

## 1. Criar o container (no Proxmox)

**Create CT** na interface:

| Campo | Valor |
|---|---|
| Hostname | `financas` |
| Unprivileged container | sim |
| Template | `debian-12-standard` (descarregar em *local → CT Templates → Templates* se não houver) |
| Disco | 8 GB |
| CPU | 1 core |
| Memória | 1024 MB (o build precisa; parada usa ~150 MB) · Swap 512 MB |
| Rede | DHCP |

**Antes de o arrancar**, no shell do Proxmox (host), dar-lhe acesso ao `/dev/net/tun` para o Tailscale
(trocar `105` pelo ID do container):

```bash
cat >> /etc/pve/lxc/105.conf <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
```

Ativar **Start at boot** em *Options* e arrancar o container.

## 2. Instalar (no container)

Na consola do container (*financas → Console*), como root:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/ricardowth/homelab.git /opt/homelab
/opt/homelab/scripts/install.sh /opt/homelab/apps/financas.conf
```

Pede a password da app e a dos backups, instala tudo e no fim mostra os passos que faltam.

## 3. Chave de deploy no GitHub

O install mostra uma chave pública (`ssh-ed25519 …`). Em
**github.com/ricardowth/personal-finance → Settings → Deploy keys → Add deploy key**:
colar, nome `proxmox financas`, **sem** "Allow write access".

Depois, no container:

```bash
/opt/homelab/scripts/deploy.sh /opt/homelab/apps/financas.conf --forcar
systemctl start financas-deploy.timer
```

O primeiro deploy demora uns minutos (instala, compila e corre os testes).

## 4. Tailscale (HTTPS só para os teus dispositivos)

```bash
tailscale up --hostname=financas --accept-dns=false   # abrir o link que aparece e autorizar
tailscale serve --bg 3000
```

A app fica em `https://financas.<tailnet>.ts.net` (o nome completo aparece em `tailscale serve status`).
Se for o primeiro serviço com HTTPS na tailnet, o Tailscale pede para ativar *Serve* / *HTTPS Certificates*
na consola de admin — ativar **só** isso, **não** o Funnel (que publicaria a app na internet).

Na consola do Tailscale (*Machines → financas → …*): **Disable key expiry**, senão desliga-se ao fim de 180 dias.

> **DNS:** o router dá servidores de DNS do ISP em `100.x.x.x`, a mesma gama que o Tailscale usa; com o
> Tailscale ligado, o DNS deixava de funcionar (sem deploys nem certificado). O `install.sh` fixa
> `1.1.1.1` e `9.9.9.9` no container e o `--accept-dns=false` impede o Tailscale de os trocar.

## 5. Passar os dados

Na app nova: **Definições → Restaurar** com o ficheiro mais recente do backup do PC
(`G:\My Drive\Backups\Financas\financas-AAAA-MM-DD.json`). Depois, em **Definições → Backup automático**,
pôr a pasta `/srv/financas/backups`.

A partir daqui os dados reais vivem no servidor — os PCs ficam só para desenvolver.

## 6. Backup para o Google Drive

O container não tem browser, por isso a autorização faz-se no PC:

1. No PC (Windows): instalar o rclone (`winget install Rclone.Rclone`).
2. No container: `rclone config` → `n` (novo) → nome **`gdrive`** → tipo `drive` → client id/secret
   (vazios, ou os do teu próprio client — ver abaixo) → scope **`drive.file`** (o rclone só vê o que ele próprio
   cria, não o resto do Drive) → *Edit advanced config* `n` → *Use auto config?* **`n`**.
3. Ele mostra um comando `rclone authorize "drive" "…"`: correr esse comando **no PC**, autorizar no browser
   e colar o resultado (um bloco base64) de volta no container. *Shared drive* `n`, confirmar.

   > O *client_id* partilhado do rclone vai deixar de funcionar durante 2026. Para não depender dele, criar um
   > próprio: <https://rclone.org/drive/#making-your-own-client-id> (projeto no Google Cloud, ativar a Drive API,
   > OAuth client do tipo *Desktop app*) e usar esse client id/secret no passo 2 e no `rclone authorize`.
4. No container:

   ```bash
   systemctl start financas-backup.service    # primeira cópia, já
   systemctl start financas-backup.timer      # e depois de 6 em 6 horas
   ```

Os ficheiros vão para `homelab-backups/<app>` no Drive (com `drive.file` o rclone só vê as pastas que ele criou), cifrados pela app (`BACKUP_PASSWORD`).
O rclone só copia (nunca apaga do Drive).

## 7. Backup do container inteiro (no Proxmox)

*Datacenter → Backup → Add*: o container `financas`, diário, modo *Snapshot*, guardar os últimos 7.
Se o container se estragar, restaura-se daí em minutos.

## Dia a dia

| Para… | Comando (no container) |
|---|---|
| Ver se está a correr | `systemctl status financas` |
| Ver os logs da app | `journalctl -u financas -f` |
| Ver os deploys | `journalctl -u financas-deploy` |
| Publicar já, sem esperar | `systemctl start financas-deploy` |
| Repetir uma versão que falhou | `/opt/homelab/scripts/deploy.sh /opt/homelab/apps/financas.conf --forcar` |
| Voltar à versão anterior | `ls -t /srv/financas/releases` → `ln -sfn /srv/financas/releases/<sha> /srv/financas/current && systemctl restart financas` |
| Mudar passwords / configuração | editar `/srv/financas/shared/.env` → `systemctl restart financas` |
| Atualizar estes scripts | `git -C /opt/homelab pull && /opt/homelab/scripts/install.sh /opt/homelab/apps/financas.conf` |

Uma versão que falhe no build, nos testes ou ao arrancar **não substitui** a que está a correr; fica registada
e não volta a ser tentada até haver um commit novo (ou `--forcar`).

## Purrfolio (diferenças)

Os mesmos passos com `purrfolio` no lugar de `financas` (container 102, porta 5174,
[apps/purrfolio.conf](../apps/purrfolio.conf)). O que muda:

- **Sem login:** a app ouve só em `127.0.0.1` (`HOST` no `.env`), por isso só se chega lá pelo `tailscale serve`.
- **Passar os dados:** copiar a pasta `data/` do PC (`data.json`, `uploads/`, `backups/`) para `/srv/purrfolio/data`
  com o serviço parado, e `chown -R purrfolio:purrfolio`.
- **Google Drive:** reutiliza o remote `gdrive` (o mesmo client do Google) — copiar o `rclone.conf` do container das
  finanças, pelo host:

  ```bash
  pct pull 101 /root/.config/rclone/rclone.conf /root/rclone.conf
  pct exec 102 -- mkdir -p /root/.config/rclone
  pct push 102 /root/rclone.conf /root/.config/rclone/rclone.conf --perms 600 && rm /root/rclone.conf
  ```

  A app não cifra os backups, por isso os ficheiros passam por um remote **crypt**, com a password do `.env`:

  ```bash
  set -a; . /srv/purrfolio/shared/.env; set +a
  rclone config create purrfolio-cifrado crypt remote=gdrive:homelab-backups/purrfolio \
    password="$(rclone obscure "$BACKUP_PASSWORD")" --non-interactive >/dev/null
  systemctl start purrfolio-backup.service purrfolio-backup.timer
  ```

  No Drive os nomes e o conteúdo aparecem cifrados. Para recuperar: `rclone copy purrfolio-cifrado: /destino`
  num sítio com o mesmo `rclone.conf` (ou a mesma password). **Sem a password não há forma de ler o backup.**
