# Pronghorn Installer

Automated installer for [Pronghorn Library Registration System](https://github.com/pronghorn-registration/pronghorn).

## Quick Install (Ubuntu 24.04 LTS)

### Step 1: Install System Dependencies

```bash
curl -fsSL https://raw.githubusercontent.com/pronghorn-registration/installer/main/install-pronghorn.sh | sudo bash
```

This installs Docker, GitHub CLI, and Watchtower. When complete, **log out and back in** for docker group permissions.

### Step 2: Setup Pronghorn

```bash
curl -fsSL https://raw.githubusercontent.com/pronghorn-registration/installer/main/install-pronghorn.sh | bash
```

The same script detects that dependencies are installed and proceeds to:
- Authenticate with GitHub Container Registry
- Download configuration files
- Generate encryption keys and certificates
- Start the application
- Run interactive setup wizard

## How It Works

This is a **self-detecting two-phase installer**:

| Phase | Run As | What It Does |
|-------|--------|--------------|
| 1 | `sudo` | Installs Docker, gh CLI, Watchtower, creates `/opt/pronghorn` |
| 2 | Regular user | GHCR auth, downloads configs, starts containers, runs setup |

The script automatically detects which phase to run based on system state.

## Requirements

- Ubuntu 24.04 LTS server (minimum 2GB RAM, 20GB disk)
- Root or sudo access
- GitHub account with access to `pronghorn-registration` organisation

## Other Distributions

Currently only Ubuntu 24.04 LTS is supported. For other distributions:

1. Install Docker Engine manually
2. Install GitHub CLI (`gh`)
3. Add your user to the `docker` group
4. Run the Phase 2 setup (the script will detect dependencies are present)

## What Gets Installed

```
/opt/pronghorn/
├── docker-compose.prod.yml   # Container orchestration
├── .env                      # Configuration
├── storage/                  # Logs, cache, uploads
├── database/                 # SQLite database
└── docker/ssl/               # SSL certificates
```

System components:
- Docker Engine + Compose
- GitHub CLI (for GHCR authentication)
- Watchtower (automatic container updates)

## Post-Installation

See the [main Pronghorn documentation](https://github.com/pronghorn-registration/pronghorn/blob/main/docs/INSTALLATION.md) for:
- ILS credential configuration
- SSL certificate installation
- SAML certificate registration with Alberta.ca IAM

## Related

- [Pronghorn](https://github.com/pronghorn-registration/pronghorn) - Main application repository
- [Installation Guide](https://github.com/pronghorn-registration/pronghorn/blob/main/docs/INSTALLATION.md) - Detailed documentation
