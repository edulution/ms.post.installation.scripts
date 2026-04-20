# MindSpark Post-Installation Scripts

Repeatable, version-controlled post-installation tooling for MindSpark servers and Access Points.

## Overview

This repository contains:

| Item | Purpose |
|------|---------|
| `mindspark_setup.sh` | Interactive post-installation script for new MindSpark servers (Ubuntu 20.04 or 24.04) |
| `configs/` | Default configuration templates (Netplan, DHCP, AnyDesk) |
| `docs/ap-standard.md` | Standardised Access Point configuration guide |

## What the script does

1. **Sets a static IP** — selects Zambia or South Africa, then applies the country-specific server IP automatically.
2. **Installs/configures Chrome** — installs Google Chrome where supported, sets the server URL as the homepage and startup page, adds a managed `MindSpark` bookmark, disables password saving/auto sign-in, and turns off the requested Google service settings.
3. **Installs/refreshes AnyDesk** — adds the official AnyDesk repository and GPG key, installs AnyDesk if missing, then clears retained AnyDesk state so a fresh AnyDesk ID is generated on each script run.
4. **Installs & configures isc-dhcp-server** — sets up the DHCP scope so client devices automatically receive the educational-content broadcast.

### Workflow

```
Run script ➜ Answer prompts ➜ Review summary ➜ Confirm ➜ Apply ➜ Verify
```

The script is **fully interactive**: it collects all inputs first, displays a clear summary for confirmation, applies changes only after approval, and verifies every service at the end.

## Quick start

```bash
# Clone the repo
git clone git@github.com:edulution/ms.post.installation.scripts.git
cd ms.post.installation.scripts

# Make the script executable
chmod +x mindspark_setup.sh

# Run the script (it will prompt for sudo automatically)
./mindspark_setup.sh
```

## Requirements

- Ubuntu 20.04 LTS or 24.04 LTS (server)
- Root / sudo access
- Internet connectivity is **optional** — all required `.deb` packages are bundled in `offline-packages/`

## Bundled packages (offline-ready)

The `offline-packages/` directory ships with every `.deb` needed to run the script without internet:

- **Google Chrome** (`google-chrome-stable*.deb`) and its dependencies
- **AnyDesk** (`anydesk*.deb`) and its dependencies
- **isc-dhcp-server** and its dependencies
- **whiptail** and its dependencies

The script uses a **local-first** install strategy:

1. Before any phase runs, all bundled `.deb` files are pre-installed via `dpkg`.
2. When a specific package is needed, the script checks if it is already installed.
3. If not, it looks for a matching `.deb` in `offline-packages/` and installs it.
4. Only if no local package is found does it fall back to `apt-get` (requires internet).

This means the script works fully offline out of the box — no flags or environment variables needed.

## Testing policy

- All development and initial testing is performed on the **spare/test server** (no learner data).
- Production deployment only occurs during **approved downtime windows**.

## Repository structure

```
.
├── README.md
├── mindspark_setup.sh          # Main post-installation script
├── offline-packages/           # Bundled .deb packages (offline-ready)
│   ├── anydesk.deb
│   ├── google-chrome-stable_current_amd64.deb
│   ├── isc-dhcp-server_*.deb
│   ├── whiptail_*.deb
│   └── ... (all dependencies)
├── configs/
│   ├── netplan-template.yaml   # Netplan static-IP template
│   └── dhcpd.conf.template     # isc-dhcp-server config template
└── docs/
    └── ap-standard.md          # Access Point standardisation guide
```

## Contributing

1. Create a feature branch from `main`.
2. Test changes on the spare server.
3. Open a pull request with a clear description.

## License

Internal use only at Edulution Africa.
