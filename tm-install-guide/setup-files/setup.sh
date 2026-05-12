#!/usr/bin/env bash
# =============================================================================
# OpenMRS Infrastructure Setup Script
# Target : Ubuntu 22.04 LTS
# Stack  : Rootless Docker  (no system daemon)
#          nginx + certbot  on HOST  (apt / snap)
#          MySQL 5.7        in Docker container
#          OpenJDK 8 + Tomcat 8.0.52 + OpenMRS 2.1.4 + RefApp 2.8.0
#                           in Docker container
# Usage  : sudo ./setup.sh [OPTIONS]
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/openmrs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a command as the deploy user with the rootless Docker environment set.
run_as_deploy() {
    sudo -u "$DEPLOY_USER" -- \
        env HOME="$DEPLOY_HOME" \
            XDG_RUNTIME_DIR="/run/user/$DEPLOY_UID" \
            DOCKER_HOST="unix:///run/user/$DEPLOY_UID/docker.sock" \
            PATH="$DEPLOY_HOME/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."

    if [[ $EUID -ne 0 ]]; then
        log_error "Run this script with sudo: sudo $0 $*"
        exit 1
    fi

    if [[ -z "${SUDO_USER:-}" ]]; then
        log_error "Run via sudo as a non-root user (SUDO_USER is not set)."
        log_error "Example: sudo $0 --domain emr.example.com --email you@example.com"
        exit 1
    fi

    DEPLOY_USER="$SUDO_USER"
    DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
    DEPLOY_UID=$(id -u "$DEPLOY_USER")

    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        log_warn "Designed for Ubuntu 22.04. Proceeding on unsupported OS."
    fi

    local env_file="${SCRIPT_DIR}/.env"
    if [[ ! -f "$env_file" ]]; then
        log_error ".env not found at ${env_file}"
        exit 1
    fi

    if grep -q "CHANGE_ME" "$env_file"; then
        log_error "Placeholder passwords detected in ${env_file}."
        log_error "Set strong values for MYSQL_ROOT_PASSWORD and MYSQL_PASSWORD before running."
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$env_file"

    log_info "Pre-flight OK — deploying as user: ${DEPLOY_USER} (uid=${DEPLOY_UID})"
}

# ---------------------------------------------------------------------------
# Step 1: Install nginx and certbot prerequisites on the HOST
# ---------------------------------------------------------------------------
install_host_packages() {
    log_info "Installing host packages (nginx, snapd, rootless Docker deps)..."

    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

    apt-get update -qq
    apt-get install -y --no-install-recommends \
        nginx \
        snapd \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        uidmap \
        dbus-user-session \
        fuse-overlayfs

    systemctl enable --now nginx
    log_info "nginx installed and running."
}

# ---------------------------------------------------------------------------
# Step 2: Install rootless Docker for the deploy user
# ---------------------------------------------------------------------------
install_rootless_docker() {
    log_info "Installing rootless Docker for user: ${DEPLOY_USER}..."

    # Add Docker's official apt repo (needed for docker-ce-rootless-extras)
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" \
          | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
    fi

    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-ce-rootless-extras \
        docker-buildx-plugin \
        docker-compose-plugin

    # Ensure the system Docker daemon is NOT running (rootless mode only)
    systemctl disable --now docker.service docker.socket 2>/dev/null || true

    # Enable linger so the user's systemd session persists across reboots
    loginctl enable-linger "$DEPLOY_USER"

    # Create XDG_RUNTIME_DIR if not yet present
    mkdir -p "/run/user/$DEPLOY_UID"
    chown "$DEPLOY_USER:$DEPLOY_USER" "/run/user/$DEPLOY_UID"
    chmod 700 "/run/user/$DEPLOY_UID"

    # Install rootless Docker daemon as the deploy user
    sudo -u "$DEPLOY_USER" -- \
        env HOME="$DEPLOY_HOME" \
            XDG_RUNTIME_DIR="/run/user/$DEPLOY_UID" \
            PATH="$DEPLOY_HOME/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        dockerd-rootless-setuptool.sh install

    # Enable and start the user-level Docker service
    sudo -u "$DEPLOY_USER" -- \
        env HOME="$DEPLOY_HOME" XDG_RUNTIME_DIR="/run/user/$DEPLOY_UID" \
        systemctl --user enable docker

    sudo -u "$DEPLOY_USER" -- \
        env HOME="$DEPLOY_HOME" XDG_RUNTIME_DIR="/run/user/$DEPLOY_UID" \
        systemctl --user start docker

    # Persist DOCKER_HOST and PATH in the user's shell profile
    local bashrc="$DEPLOY_HOME/.bashrc"
    local docker_host_line="export DOCKER_HOST=unix:///run/user/${DEPLOY_UID}/docker.sock"
    local path_line='export PATH=$HOME/bin:$PATH'
    grep -qF "$docker_host_line" "$bashrc" 2>/dev/null || echo "$docker_host_line" >> "$bashrc"
    grep -qF 'HOME/bin' "$bashrc" 2>/dev/null || echo "$path_line" >> "$bashrc"

    log_info "Rootless Docker installed. Socket: unix:///run/user/${DEPLOY_UID}/docker.sock"
}

# ---------------------------------------------------------------------------
# Step 3: Configure Docker log retention (per-user daemon config)
# ---------------------------------------------------------------------------
configure_docker_logging() {
    log_info "Configuring Docker log retention (local driver, ~3 days)..."

    local docker_cfg_dir="$DEPLOY_HOME/.config/docker"
    mkdir -p "$docker_cfg_dir"
    cat > "$docker_cfg_dir/daemon.json" <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "50m",
    "max-file": "72",
    "compress": "true"
  }
}
EOF
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$docker_cfg_dir"

    # Restart rootless daemon to pick up new config
    sudo -u "$DEPLOY_USER" -- \
        env HOME="$DEPLOY_HOME" XDG_RUNTIME_DIR="/run/user/$DEPLOY_UID" \
        systemctl --user restart docker

    log_info "Docker log retention configured."
}

# ---------------------------------------------------------------------------
# Step 4: Prepare /opt/openmrs directory tree and copy config files
# ---------------------------------------------------------------------------
create_directory_structure() {
    log_info "Creating ${INSTALL_DIR}..."

    mkdir -p "${INSTALL_DIR}"/{mysql/conf.d,app,data/modules}

    cp "${SCRIPT_DIR}/mysql/conf.d/openmrs.cnf"       "${INSTALL_DIR}/mysql/conf.d/openmrs.cnf"
    cp "${SCRIPT_DIR}/app/Dockerfile"                  "${INSTALL_DIR}/app/Dockerfile"
    cp "${SCRIPT_DIR}/app/start.sh"                    "${INSTALL_DIR}/app/start.sh"
    chmod +x "${INSTALL_DIR}/app/start.sh"

    cp "${SCRIPT_DIR}/data/openmrs-runtime.properties" "${INSTALL_DIR}/data/openmrs-runtime.properties"
    local db_pass
    db_pass=$(grep '^MYSQL_PASSWORD=' "${SCRIPT_DIR}/.env" | cut -d= -f2-)
    sed -i "s|^connection\.password=.*|connection.password=${db_pass}|" \
        "${INSTALL_DIR}/data/openmrs-runtime.properties"

    cp "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
    cp "${SCRIPT_DIR}/.env"               "${INSTALL_DIR}/.env"
    chmod 600 "${INSTALL_DIR}/.env"

    chown -R "$DEPLOY_USER:$DEPLOY_USER" "${INSTALL_DIR}"

    log_info "Directory structure created."
}

# ---------------------------------------------------------------------------
# Step 5: Download OpenMRS Reference Application 2.8.0 module
# ---------------------------------------------------------------------------
download_modules() {
    log_info "Downloading OpenMRS Reference Application 2.8.0 module..."

    local omod_url="https://github.com/openmrs/openmrs-module-referenceapplication/releases/download/2.8.0/referenceapplication-2.8.0.omod"
    local dest="${INSTALL_DIR}/data/modules/referenceapplication-2.8.0.omod"

    if [[ -f "$dest" ]]; then
        log_info "Module already present, skipping download."
        return 0
    fi

    wget -q --tries=3 "$omod_url" -O "$dest" || {
        log_warn "Module download failed. Download manually to ${INSTALL_DIR}/data/modules/"
        log_warn "URL: ${omod_url}"
        return 0
    }

    chown "$DEPLOY_USER:$DEPLOY_USER" "$dest"
    log_info "Module downloaded."
}

# ---------------------------------------------------------------------------
# Step 6: Build and start the Docker stack (as deploy user)
# ---------------------------------------------------------------------------
start_stack() {
    log_info "Building and starting OpenMRS stack (mysql + openmrs)..."

    run_as_deploy bash -c "cd ${INSTALL_DIR} && docker compose up -d --build"

    log_info "Waiting for MySQL to become healthy (up to 120 s)..."
    local retries=0
    while [[ $retries -lt 24 ]]; do
        if run_as_deploy docker exec openmrs-mysql \
            mysqladmin ping -h localhost -u openmrs "-p${MYSQL_PASSWORD}" &>/dev/null; then
            log_info "MySQL is healthy."
            break
        fi
        retries=$((retries + 1))
        sleep 5
    done

    if [[ $retries -ge 24 ]]; then
        log_warn "MySQL did not become healthy within 120 s. Check: docker logs openmrs-mysql"
    fi

    log_info "OpenMRS is starting. First boot takes 5–15 minutes."
    log_info "Monitor progress: sudo -u ${DEPLOY_USER} DOCKER_HOST=unix:///run/user/${DEPLOY_UID}/docker.sock docker logs -f openmrs-app"
}

# ---------------------------------------------------------------------------
# Step 7: Configure nginx on the HOST (HTTP, no SSL yet)
# ---------------------------------------------------------------------------
configure_nginx_http() {
    log_info "Configuring nginx (HTTP) for domain: ${DOMAIN}..."

    sed "s/SERVER_NAME/${DOMAIN}/g" \
        "${SCRIPT_DIR}/nginx/openmrs.conf" \
        > /etc/nginx/sites-available/openmrs

    ln -sf /etc/nginx/sites-available/openmrs /etc/nginx/sites-enabled/openmrs
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl reload nginx
    log_info "nginx configured (HTTP)."
}

# ---------------------------------------------------------------------------
# Step 8: Install Certbot and obtain SSL certificate
# ---------------------------------------------------------------------------
install_certbot() {
    if command -v certbot &>/dev/null; then
        log_info "Certbot already installed: $(certbot --version 2>&1)"
        return 0
    fi

    log_info "Installing Certbot via snap..."
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/local/bin/certbot
    log_info "Certbot installed."
}

setup_ssl() {
    local domain="$1"
    local email="$2"

    if [[ -z "$domain" || -z "$email" ]]; then
        log_warn "Skipping SSL. Run later with:"
        echo "  sudo $0 --ssl-only --domain YOUR_DOMAIN --email YOUR_EMAIL"
        return 0
    fi

    log_info "Obtaining SSL certificate for ${domain}..."

    certbot certonly \
        --webroot \
        --webroot-path /var/www/html \
        -d "${domain}" \
        --email "${email}" \
        --agree-tos \
        --non-interactive

    # Replace HTTP config with HTTPS config
    sed "s/SERVER_NAME/${domain}/g" \
        "${SCRIPT_DIR}/nginx/openmrs-ssl.conf" \
        > /etc/nginx/sites-available/openmrs

    nginx -t
    systemctl reload nginx

    # Post-renewal hook: reload nginx after automatic renewal
    mkdir -p /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh

    log_info "SSL configured for ${domain}. HTTPS is active."
}

# ---------------------------------------------------------------------------
# Post-install summary
# ---------------------------------------------------------------------------
verify_install() {
    echo ""
    echo "============================================="
    echo "          Post-Install Verification          "
    echo "============================================="

    log_info "Container status:"
    run_as_deploy docker ps \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo ""
    log_info "Resource usage:"
    run_as_deploy docker stats --no-stream \
        --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

    echo ""
    echo "============================================="
    echo "  OpenMRS first boot: 5–15 minutes           "
    echo "  Watch logs:                                 "
    echo "    sudo -u ${DEPLOY_USER} \\"
    echo "      DOCKER_HOST=unix:///run/user/${DEPLOY_UID}/docker.sock \\"
    echo "      docker logs -f openmrs-app              "
    echo ""
    if [[ -n "${DOMAIN:-}" ]]; then
        echo "  URL: https://${DOMAIN}/openmrs             "
    else
        echo "  URL: http://<server-ip>/openmrs            "
    fi
    echo "  Login: admin / Admin123                     "
    echo "  CHANGE THE PASSWORD IMMEDIATELY!             "
    echo "============================================="
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: sudo $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --domain DOMAIN    Domain name for SSL (e.g. emr.example.com)"
    echo "  --email  EMAIL     Email for Let's Encrypt notifications"
    echo "  --ssl-only         Only run SSL setup (stack must already be running)"
    echo "  --no-ssl           Skip SSL entirely"
    echo "  --skip-docker      Skip Docker installation (if already installed)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo $0 --domain emr.example.com --email ops@example.com"
    echo "  sudo $0 --no-ssl"
    echo "  sudo $0 --ssl-only --domain emr.example.com --email ops@example.com"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local domain=""
    local email=""
    local ssl_only=false
    local no_ssl=false
    local skip_docker=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)      domain="$2"; shift 2 ;;
            --email)       email="$2";  shift 2 ;;
            --ssl-only)    ssl_only=true; shift ;;
            --no-ssl)      no_ssl=true;   shift ;;
            --skip-docker) skip_docker=true; shift ;;
            -h|--help)     usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    echo "============================================="
    echo "  OpenMRS Infrastructure Setup               "
    echo "  Ubuntu 22.04 + Rootless Docker             "
    echo "  MySQL 5.7 | OpenMRS 2.1.4 | Nginx (host)  "
    echo "============================================="
    echo ""

    preflight_checks

    DOMAIN="$domain"

    if [[ "$ssl_only" == true ]]; then
        [[ -n "$domain" && -n "$email" ]] || { log_error "--domain and --email required for --ssl-only"; exit 1; }
        install_certbot
        setup_ssl "$domain" "$email"
        log_info "SSL setup complete."
        exit 0
    fi

    if [[ "$skip_docker" == false ]]; then
        install_host_packages
        install_rootless_docker
        configure_docker_logging
    fi

    create_directory_structure
    download_modules
    start_stack

    if [[ -n "$domain" ]]; then
        configure_nginx_http
    fi

    install_certbot

    if [[ "$no_ssl" == false ]]; then
        setup_ssl "$domain" "$email"
    fi

    verify_install
    log_info "Setup complete!"
}

main "$@"
