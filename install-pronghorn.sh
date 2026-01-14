#!/usr/bin/env bash
#
# Pronghorn Unified Installer
# A self-detecting two-phase installer for Pronghorn deployment
#
# Usage:
#   First run (installs system dependencies):
#     curl -fsSL https://raw.githubusercontent.com/pronghorn-registration/installer/main/install-pronghorn.sh | sudo bash
#
#   Second run (after logout/login, configures Pronghorn):
#     curl -fsSL https://raw.githubusercontent.com/pronghorn-registration/installer/main/install-pronghorn.sh | bash
#
# The script automatically detects which phase to run based on system state.
#
set -euo pipefail

# If being piped (stdin is not a terminal), save to temp file and re-execute
# This ensures interactive prompts work properly
if [[ ! -t 0 ]] && [[ -z "${PRONGHORN_REEXEC:-}" ]]; then
    tmpscript=$(mktemp)
    cat > "$tmpscript"
    chmod +x "$tmpscript"
    export PRONGHORN_REEXEC=1
    exec bash "$tmpscript" "$@"
fi

# Configuration
INSTALL_DIR="/opt/pronghorn"
GITHUB_REPO="pronghorn-registration/pronghorn"
GHCR_IMAGE="ghcr.io/pronghorn-registration/pronghorn:latest"
INSTALLER_URL="https://raw.githubusercontent.com/pronghorn-registration/installer/main/install-pronghorn.sh"

# Colour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

# ============================================================================
# Phase Detection
# ============================================================================
detect_phase() {
    # Check if Docker is installed
    if ! command -v docker &>/dev/null; then
        echo "install"
        return
    fi

    # Check if user has docker access (in docker group or is root)
    if ! docker info &>/dev/null 2>&1; then
        echo "relogin"
        return
    fi

    # Check if gh CLI is installed
    if ! command -v gh &>/dev/null; then
        echo "install"
        return
    fi

    # Docker works, gh exists - ready for setup
    echo "setup"
}

# ============================================================================
# Phase 1: System Dependencies (requires sudo)
# ============================================================================
phase_install() {
    header "Phase 1: Installing System Dependencies"

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "Phase 1 requires root privileges."
        error "Run with: curl -fsSL $INSTALLER_URL | sudo bash"
        exit 1
    fi

    # Detect the real user (who invoked sudo)
    REAL_USER="${SUDO_USER:-$USER}"
    if [[ "$REAL_USER" == "root" ]]; then
        warn "Running as root directly. Consider using a regular user with sudo."
    fi

    # Detect OS
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" ]]; then
        error "This installer is designed for Ubuntu. Detected: $ID"
        exit 1
    fi

    info "Installing on Ubuntu $VERSION_ID for user: $REAL_USER"

    # Suppress interactive prompts during package installation
    export DEBIAN_FRONTEND=noninteractive

    # Update system
    info "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold"
    success "System updated"

    # Install prerequisites
    info "Installing prerequisites..."
    apt-get install -y -qq -o Dpkg::Options::="--force-confold" \
        curl \
        git \
        openssl \
        ca-certificates \
        apt-transport-https \
        software-properties-common \
        gnupg \
        lsb-release
    success "Prerequisites installed"

    # Install Docker
    if command -v docker &>/dev/null; then
        success "Docker already installed"
    else
        info "Installing Docker Engine..."

        # Remove old versions
        apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

        # Add Docker repository
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -qq
        apt-get install -y -qq -o Dpkg::Options::="--force-confold" \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

        systemctl enable docker
        systemctl start docker
        success "Docker installed"
    fi

    # Add user to docker group
    if groups "$REAL_USER" 2>/dev/null | grep -q '\bdocker\b'; then
        success "User '$REAL_USER' already in docker group"
    else
        info "Adding user '$REAL_USER' to docker group..."
        usermod -aG docker "$REAL_USER"
        success "User added to docker group"
    fi

    # Install GitHub CLI
    if command -v gh &>/dev/null; then
        success "GitHub CLI already installed"
    else
        info "Installing GitHub CLI..."

        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
            dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
            tee /etc/apt/sources.list.d/github-cli.list > /dev/null

        apt-get update -qq
        apt-get install -y -qq -o Dpkg::Options::="--force-confold" gh
        success "GitHub CLI installed"
    fi

    # Deploy Watchtower
    if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        success "Watchtower already deployed"
    else
        info "Deploying Watchtower for automatic updates..."
        docker run -d \
            --name watchtower \
            --restart unless-stopped \
            -v /var/run/docker.sock:/var/run/docker.sock \
            nickfedor/watchtower --interval 300
        success "Watchtower deployed"
    fi

    # Create install directory
    if [[ ! -d "$INSTALL_DIR" ]]; then
        info "Creating $INSTALL_DIR..."
        mkdir -p "$INSTALL_DIR"
        chown "$REAL_USER:$REAL_USER" "$INSTALL_DIR"
        success "Directory created"
    fi

    # Done with Phase 1
    echo ""
    echo "=============================================="
    echo -e "${GREEN}Phase 1 Complete!${NC}"
    echo "=============================================="
    echo ""
    echo "Installed:"
    echo "  - Docker Engine $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    echo "  - Docker Compose $(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    echo "  - GitHub CLI $(gh --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+')"
    echo "  - Watchtower (auto-update daemon)"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Log out and back in for docker group to take effect.${NC}"
    echo ""
    echo "Then run this script again (without sudo):"
    echo -e "  ${CYAN}curl -fsSL $INSTALLER_URL | bash${NC}"
    echo ""
}

# ============================================================================
# Phase 2: Pronghorn Setup (runs as regular user)
# ============================================================================
phase_setup() {
    header "Phase 2: Pronghorn Setup"

    # Should NOT be root for this phase - auto-drop privileges if possible
    if [[ $EUID -eq 0 ]]; then
        if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
            info "Dropping privileges to '$SUDO_USER' for Phase 2..."
            # Download to temp file so stdin is free for user input
            local tmpscript
            tmpscript=$(mktemp)
            curl -fsSL "$INSTALLER_URL" -o "$tmpscript"
            chmod +x "$tmpscript"
            exec sudo -u "$SUDO_USER" bash "$tmpscript"
        fi
        # Running as root directly (not via sudo)
        warn "Phase 2 should run as a regular user, not root."
        warn "This ensures GitHub credentials are stored in your home directory."
        echo ""
        read -p "Continue as root anyway? [y/N]: " -r < /dev/tty
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Run without sudo: curl -fsSL $INSTALLER_URL | bash"
            exit 0
        fi
    fi

    cd "$INSTALL_DIR" || {
        error "Cannot access $INSTALL_DIR"
        exit 1
    }

    # Step 1: GHCR Authentication
    setup_ghcr_auth

    # Step 2: Download required files
    download_files

    # Step 3: Bootstrap environment
    bootstrap_environment

    # Step 4: Start containers
    start_containers

    # Step 5: Run interactive setup
    run_artisan_setup

    echo ""
    echo "=============================================="
    echo -e "${GREEN}Pronghorn Installation Complete!${NC}"
    echo "=============================================="
    echo ""
}

# ============================================================================
# GHCR Authentication
# ============================================================================
setup_ghcr_auth() {
    info "Setting up GitHub Container Registry authentication..."

    # Check if already authenticated
    if docker pull "$GHCR_IMAGE" &>/dev/null 2>&1; then
        success "Already authenticated with GHCR"
        return 0
    fi

    # Check GitHub CLI auth
    if ! gh auth status &>/dev/null 2>&1; then
        echo ""
        echo "GitHub CLI needs authentication."
        echo ""
        echo "Options:"
        echo "  1. Browser authentication (recommended)"
        echo "  2. Personal Access Token (for headless servers)"
        echo ""
        read -p "Choose [1/2]: " -r auth_choice < /dev/tty

        case "$auth_choice" in
            2)
                echo ""
                echo "Create a token at: https://github.com/settings/tokens/new"
                echo "Required scopes: read:packages, write:packages"
                echo ""
                read -sp "Enter token: " gh_token < /dev/tty
                echo ""
                echo "$gh_token" | gh auth login --with-token
                success "Authenticated with PAT"
                ;;
            *)
                info "Opening browser for GitHub authentication..."
                gh auth login -h github.com -p https -w
                ;;
        esac
    fi

    # Add package scopes
    info "Adding package scopes..."
    gh auth refresh -h github.com -s read:packages,write:packages 2>/dev/null || true

    # Authenticate Docker with GHCR
    info "Authenticating Docker with GHCR..."
    local gh_user
    gh_user=$(gh api user --jq '.login' 2>/dev/null) || {
        error "Could not determine GitHub username"
        exit 1
    }

    gh auth token | docker login ghcr.io -u "$gh_user" --password-stdin
    success "Docker authenticated as $gh_user"

    # Pull image
    info "Pulling Pronghorn image..."
    docker pull "$GHCR_IMAGE"
    success "Image pulled"
}

# ============================================================================
# Download Required Files
# ============================================================================
download_files() {
    info "Downloading configuration files..."

    # Download docker-compose.prod.yml from private repo (requires gh auth)
    if [[ ! -f "docker-compose.prod.yml" ]]; then
        info "Fetching docker-compose.prod.yml from $GITHUB_REPO..."
        gh api "repos/$GITHUB_REPO/contents/docker-compose.prod.yml" --jq '.content' | base64 -d > docker-compose.prod.yml
        success "Downloaded docker-compose.prod.yml"
    else
        success "docker-compose.prod.yml exists"
    fi

    # Create directories
    mkdir -p storage/certs storage/logs storage/framework/{sessions,views,cache/data}
    mkdir -p database docker/ssl
    success "Directories created"
}

# ============================================================================
# Bootstrap Environment
# ============================================================================
bootstrap_environment() {
    info "Bootstrapping environment..."

    # Create .env if needed
    if [[ ! -f ".env" ]]; then
        # Generate APP_KEY
        info "Generating APP_KEY..."
        local app_key
        app_key=$(docker run --rm --entrypoint php "$GHCR_IMAGE" artisan key:generate --show 2>/dev/null)

        if [[ -z "$app_key" ]]; then
            error "Failed to generate APP_KEY"
            exit 1
        fi

        # Create minimal .env with production defaults
        cat > .env << EOF
APP_NAME=Pronghorn
APP_ENV=production
APP_KEY=$app_key
APP_DEBUG=false
APP_URL=https://localhost

INSTANCE_ID=default

DB_CONNECTION=sqlite

REDIS_HOST=redis
REDIS_PORT=6379
CACHE_STORE=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis

ILS_DRIVER=symphony
EOF

        success "Environment configured with new APP_KEY"
    else
        success "Using existing .env"
    fi

    # Generate SSL certificates if needed
    if [[ ! -f "docker/ssl/fullchain.pem" ]] || [[ ! -f "docker/ssl/privkey.pem" ]]; then
        info "Generating placeholder SSL certificates..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout docker/ssl/privkey.pem \
            -out docker/ssl/fullchain.pem \
            -subj "/CN=localhost/O=Pronghorn/C=CA" \
            2>/dev/null
        success "SSL certificates generated (self-signed)"
        warn "Replace with production certificates before going live"
    fi
}

# ============================================================================
# Start Containers
# ============================================================================
start_containers() {
    info "Starting containers..."

    # Stop existing containers
    if docker compose -f docker-compose.prod.yml ps -q 2>/dev/null | grep -q .; then
        info "Stopping existing containers..."
        docker compose -f docker-compose.prod.yml down
    fi

    docker compose -f docker-compose.prod.yml up -d
    success "Containers started"

    # Wait for healthy
    info "Waiting for application to become healthy..."
    local attempts=0
    local max_attempts=30

    while [[ $attempts -lt $max_attempts ]]; do
        if docker compose -f docker-compose.prod.yml ps 2>/dev/null | grep -q "(healthy)"; then
            echo ""
            success "Application is healthy!"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempts++))
    done

    echo ""
    warn "Health check timed out - container may still be initializing"
}

# ============================================================================
# Run Artisan Setup
# ============================================================================
run_artisan_setup() {
    header "Interactive Configuration"

    # Give container a moment to fully initialize
    sleep 2

    docker exec -it pronghorn-pronghorn-1 php artisan pronghorn:setup
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo -e "${BOLD}Pronghorn Installer${NC}"
    echo "==================="
    echo ""

    local phase
    phase=$(detect_phase)

    case "$phase" in
        install)
            phase_install
            ;;
        relogin)
            echo -e "${YELLOW}Docker is installed but you need to log out and back in${NC}"
            echo "for your user to have docker access."
            echo ""
            echo "After logging back in, run this script again (without sudo):"
            echo -e "  ${CYAN}curl -fsSL $INSTALLER_URL | bash${NC}"
            echo ""
            exit 0
            ;;
        setup)
            phase_setup
            ;;
        *)
            error "Unknown phase: $phase"
            exit 1
            ;;
    esac
}

main "$@"
