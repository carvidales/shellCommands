# Example utility scripts

These are **opt-in examples** for Linux/WSL, not scripts installed automatically.
The application deliberately ignores `scripts/` so personal scripts and secrets
remain local. To use an example, copy it into `scripts/` or paste its contents
into the app's editor:

```bash
mkdir -p scripts
cp examples/system-info.sh scripts/system-info.sh
```

## Available commands

| File | Purpose | Optional first argument |
| --- | --- | --- |
| `kill-port.sh` | Gracefully stop processes listening on a port | Port (default 8000) |
| `listening-ports.sh` | List listening TCP/UDP sockets | None |
| `git-status.sh` | Show branch, changes, and latest commit | Project directory |
| `docker-status.sh` | Running Docker containers and disk usage | None |
| `largest-files.sh` | Ten largest files in a directory | Directory |
| `ssl-expiration.sh` | Print a domain's TLS certificate dates | Domain |
| `api-response-time.sh` | HTTP status and request timing | URL |
| `generate-password.sh` | Generate a random password | None |
| `system-info.sh` | Memory, disk, uptime, and processes | None |

Edit defaults before copying scripts into the dashboard. The dashboard runs
scripts from your home directory, not the repository directory, and has no
interactive parameter input.

**Security:** the dashboard retains stdout/stderr in run history. Never use
`generate-password.sh` in the dashboard, because generated secrets would be
stored in those logs. Run that script only in a private terminal.

**Port warning:** if the dashboard itself runs on port 3000, a kill-port
script targeting 3000 would stop the dashboard. Use a different port for the
dashboard when managing port 3000.

The commands depend on standard Linux utilities such as `curl`, `ss`,
`lsof`, `openssl`, and `numfmt`, and Docker for the Docker example.
