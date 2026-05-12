# OpenMRS Setup Guide

Deploys OpenMRS 2.1.4 on a single Ubuntu 22.04 server using **rootless Docker** (no system daemon), with **nginx and certbot running directly on the host**.

## Architecture

| Component | Where | Port |
|-----------|-------|------|
| nginx reverse proxy | Host (apt) | 80 / 443 |
| Certbot | Host (snap) | — |
| MySQL 5.7 | Docker container | 127.0.0.1:3306 |
| OpenJDK 8 + Tomcat 8.0.52 + OpenMRS 2.1.4 + RefApp 2.8.0 | Docker container | 127.0.0.1:8080 |

Both containers are on an isolated Docker bridge network (`openmrs-net`). Neither MySQL nor OpenMRS is reachable from outside the server — nginx proxies public traffic to OpenMRS on port 8080.

## Repository Layout

```
install-guide/
└── setup-files/
    ├── setup.sh                        # Main installer (run with sudo)
    ├── docker-compose.yml              # MySQL + OpenMRS containers
    ├── .env                            # DB credentials (edit before running)
    ├── app/
    │   ├── Dockerfile                  # OpenJDK 8 + Tomcat 8 + OpenMRS WAR
    │   └── start.sh                    # Tomcat startup with JVM tuning
    ├── data/
    │   ├── openmrs-runtime.properties  # DB connection config
    │   └── modules/                    # OpenMRS .omod files (auto-downloaded)
    ├── mysql/
    │   └── conf.d/openmrs.cnf          # MySQL tuning (InnoDB, charset, etc.)
    └── nginx/
        ├── openmrs.conf                # HTTP vhost (used before SSL)
        └── openmrs-ssl.conf            # HTTPS vhost (activated after SSL)
```

## Prerequisites

- Ubuntu 22.04 LTS (fresh server recommended)
- A non-root user with sudo access
- DNS A record pointing your domain to the server IP
- Ports 80 and 443 open in the firewall

## Step 1 — Set Passwords

Copy the example file and set real values:

```bash
cp setup-files/.env.example setup-files/.env
```

Edit `setup-files/.env` and replace the placeholder values:

```dotenv
MYSQL_ROOT_PASSWORD=<strong-root-password>
MYSQL_PASSWORD=<strong-openmrs-password>
```

> The setup script refuses to run while `CHANGE_ME` values are present.

## Step 2 — Run the Installer

```bash
cd setup-files
sudo ./setup.sh --domain emr.example.com --email admin@example.com
```

**What happens:**

1. Installs nginx on the host (apt) and starts it
2. Installs rootless Docker for the invoking user — the Docker daemon runs without root
3. Configures Docker log retention (50 MB/file, 72 files ≈ 3 days)
4. Creates `/opt/openmrs/` and copies all config files
5. Injects the DB password from `.env` into `openmrs-runtime.properties`
6. Downloads the OpenMRS Reference Application 2.8.0 `.omod`
7. Builds and starts the MySQL and OpenMRS containers
8. Configures nginx on the host to proxy `http://<domain>` → `localhost:8080`
9. Installs Certbot via snap and obtains a Let's Encrypt certificate
10. Swaps the nginx vhost to HTTPS and installs an auto-renewal hook

**Options:**

```
--domain DOMAIN    Domain for SSL (e.g. emr.example.com)
--email  EMAIL     Email for Let's Encrypt notifications
--ssl-only         Only run the SSL step (requires --domain and --email)
--no-ssl           Skip SSL entirely
--skip-docker      Skip Docker installation (if already installed)
-h, --help         Show help
```

## First-Time Login

OpenMRS first boot takes **5–15 minutes** while it initialises the database.

```bash
# Watch startup progress (run as your non-root user)
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker logs -f openmrs-app
```

Once ready:

```
URL:      https://emr.example.com/openmrs
Username: admin
Password: Admin123
```

**Change the admin password immediately after first login.**

## Day-2 Operations

All `docker` commands must be run as the deploy user (the user who ran setup), not as root.

```bash
# Container status
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker ps

# Live logs
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker logs -f openmrs-app
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker logs -f openmrs-mysql

# Resource usage
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker stats --no-stream

# Restart the stack
cd /opt/openmrs
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker compose restart

# Stop (keeps data volume)
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker compose down

# Stop and delete database (DESTRUCTIVE)
DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker compose down -v

# Test SSL certificate renewal
sudo certbot renew --dry-run
```

> **Tip:** Add `export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock` to your `~/.bashrc` (the installer does this automatically) so you can run `docker` without the prefix.

## Security Checklist

- [ ] Replace `CHANGE_ME` values in `setup-files/.env` before running
- [ ] Add `setup-files/.env` to `.gitignore` — never commit credentials
- [ ] Change the default OpenMRS admin password after first login
- [ ] MySQL listens on `127.0.0.1:3306` only — confirm with `ss -tlnp | grep 3306`
- [ ] OpenMRS listens on `127.0.0.1:8080` only — confirm with `ss -tlnp | grep 8080`
- [ ] HSTS header is included in `nginx/openmrs-ssl.conf` by default
- [ ] Certbot auto-renewal reloads nginx via `/etc/letsencrypt/renewal-hooks/post/reload-nginx.sh`
