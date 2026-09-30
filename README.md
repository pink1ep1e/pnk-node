# pnk-node

Скрипт для установки и управления **Remnawave Node**

---

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pink1ep1e/pnk-node/refs/heads/main/install.sh)
```

или

```bash
curl -fsSL https://raw.githubusercontent.com/pink1ep1e/pnk-node/refs/heads/main/install.sh -o install.sh && chmod +x install.sh && sudo bash ./install.sh
```

---

## Возможности

### Remnanode

- Полная установка ноды (Docker + multi-IP + policy routing + NAT + UFW)
- Несколько нод на одном сервере
- Обновление и удаление
- Логи и диагностика
- Безопасность (UFW + anti-ping)

### Extras

- Self-steal: **Caddy** или **Nginx** для Reality dest
- Nginx: proxy protocol, сертификаты Cloudflare DNS-01 / HTTP-01 / Gcore DNS-01
- CDN: nginx + Let's Encrypt, `/api/uploadFile/` → `127.0.0.1:4443`
- WARP-NATIVE
- BBR оптимизация

---

## Меню

| # | Действие |
|---|----------|
| 1 | Установить ноду |
| 2 | Удалить ноду |
| 3 | Безопасность |
| 4 | Логи |
| 5 | Обновить ноду |
| 6 | Диагностика |
| 7 | Self-steal (Caddy / Nginx) |
| 8 | BBR |
| 9 | WARP-NATIVE |
| 10 | CDN (nginx + LE) |
| 0 | Выход |

После установки: `pnk-node` или `sudo bash /opt/pnk-node-suite/menu.sh`

---

## Требования

- Ubuntu 20.04 / 22.04 / 24.04 или Debian 11 / 12
- Root
- ~512 MB RAM, 1 GB disk

## Лицензия

MIT
