# homelab

Scripts para correr as apps pessoais no servidor Proxmox: um container LXC por app, publicação automática
a partir do GitHub, HTTPS pela tailnet (Tailscale) e backups para o Google Drive.

| Pasta | O quê |
|---|---|
| [apps/](apps/) | Um `.conf` por app: repo, porta, comandos de build/teste/arranque, backups |
| [scripts/install.sh](scripts/install.sh) | Prepara o container (Node, systemd, deploy, Tailscale, rclone) |
| [scripts/deploy.sh](scripts/deploy.sh) | Publica a versão nova se o build, os testes e o arranque passarem |
| [docs/proxmox.md](docs/proxmox.md) | Passo a passo, do container novo à app no ar |

## Apps

| App | Repo | Endereço |
|---|---|---|
| financas | ricardowth/personal-finance | `https://financas.<tailnet>.ts.net` |

## Como funciona o deploy

```
GitHub (main) ──git ls-remote de 5 em 5 min──▶ container
                                              │ commit novo?
                                              ▼
                     /srv/<app>/releases/<sha>  ← clone + npm ci + build + testes
                                              │ tudo passou
                                              ▼
                     /srv/<app>/current ──▶ <sha>   e restart do serviço
                                              │ responde em HEALTH_PATH?
                                   sim ◀──────┴──────▶ não: volta à versão anterior
```

Os dados (`/srv/<app>/data`) e o `.env` (`/srv/<app>/shared`) ficam fora das versões, por isso
publicar ou voltar atrás nunca lhes mexe. O acesso ao GitHub é uma *deploy key* só de leitura.

## Nova app

Copiar [apps/financas.conf](apps/financas.conf) para `apps/<app>.conf`, ajustar, e seguir
[docs/proxmox.md](docs/proxmox.md) com o nome novo.
