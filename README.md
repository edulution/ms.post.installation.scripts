# MindSpark Post-Installation Scripts

Repeatable, version-controlled post-installation tooling for MindSpark servers and Access Points.

## Overview

This repository contains:

| Item | Purpose |
|------|---------|
| `mindspark_setup.sh` | Interactive post-installation script for new MindSpark servers (Ubuntu 24.04) |
| `configs/` | Default configuration templates (Netplan, DHCP, AnyDesk) |
| `docs/ap-standard.md` | Standardised Access Point configuration guide |

## What the script does

1. **Installs AnyDesk** — adds the official AnyDesk repository and GPG key, then installs the package for reliable remote support.
2. **Sets a static IP** — configures Netplan with the correct static IP mapped to the server's hostname (`mindsparkserverr`).
3. **Installs & configures isc-dhcp-server** — sets up the DHCP scope so client devices automatically receive the educational-content broadcast.

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

# Run with sudo (required for system configuration)
sudo ./mindspark_setup.sh
```

## Requirements

- Ubuntu 24.04 LTS (server)
- Root / sudo access
- Internet connectivity (for AnyDesk repository)

## Testing policy

- All development and initial testing is performed on the **spare/test server** (no learner data).
- Production deployment only occurs during **approved downtime windows**.

## Repository structure

```
.
├── README.md
├── mindspark_setup.sh          # Main post-installation script
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

Internal use only — MindSpark Post-installation project.
