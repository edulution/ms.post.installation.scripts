# MindSpark Post-Installation Scripts

Repeatable, version-controlled post-installation tooling for MindSpark servers and Access Points.

---

## Overview

| Item | Purpose |
|------|---------|
| `mindspark_setup.sh` | Interactive post-installation script for new MindSpark servers (Ubuntu 20.04 or 24.04 LTS) |
| `configs/` | Default configuration templates (Netplan, DHCP) |
| `docs/ap-standard.md` | Standardised Access Point configuration guide |

---

## What the script does

1. **Static IP via Netplan** — Selects country (Zambia or South Africa), applies the country-specific server IP, configures primary and secondary DNS, and writes a Netplan config.
2. **Google Chrome** — Installs Chrome, sets the MindSpark content server as the homepage and startup page, creates a managed `MindSpark` bookmark, and locks down password saving and auto sign-in.
3. **AnyDesk** — Adds the official AnyDesk repository, installs AnyDesk if missing, then clears retained state so a fresh AnyDesk ID is generated.
4. **Kea DHCP4** — Installs and configures `kea-dhcp4` so client devices automatically receive IP addresses and reach the educational-content server. The correct package is selected automatically based on the Ubuntu version:
   - Ubuntu 20.04: `kea-dhcp4-server`
   - Ubuntu 24.04: `kea-dhcp4`
5. **Access Point MAC reservation** — Scans the local subnet via ARP to detect the Access Point, then writes a static DHCP reservation so the AP always receives the same IP (see [Access Point MAC address](#access-point-mac-address) below).
6. **NTP** — Configures `systemd-timesyncd` with `time.cloudflare.com` and `ntp.ubuntu.com` for reliable time synchronisation.

### Workflow

```
Run script → Answer prompts → Review summary → Confirm → Apply → Verify
```

The script is **fully interactive**: all inputs are collected first, a summary is displayed for review, changes are applied only after operator approval, and every service is verified at the end.

### Hostname behaviour

The script does **not** change the system hostname. The optional server number prompt is used for operator labelling only.

---

## Deployment — Getting the script onto a MindSpark server

### Option 1 — Git (recommended)

```bash
sudo apt-get install -y git          # install git if not present
git clone https://github.com/edulution/ms.post.installation.scripts.git
cd ms.post.installation.scripts
chmod +x mindspark_setup.sh
./mindspark_setup.sh
```

### Option 2 — Download archive (no git required)

```bash
wget -O mindspark-setup.zip \
  https://github.com/edulution/ms.post.installation.scripts/archive/refs/heads/main.zip
unzip mindspark-setup.zip
cd ms.post.installation.scripts-main
chmod +x mindspark_setup.sh
./mindspark_setup.sh
```

### Option 3 — Single-file download (minimal footprint)

```bash
wget -O mindspark_setup.sh \
  https://raw.githubusercontent.com/edulution/ms.post.installation.scripts/main/mindspark_setup.sh
chmod +x mindspark_setup.sh
./mindspark_setup.sh
```

> The script requests `sudo` automatically — do **not** run it as root directly.

---

## Requirements

- Ubuntu 20.04 LTS or 24.04 LTS
- `sudo` access
- Internet connectivity (required for first-time package installation)

---

## Access Point MAC address

### Background

All Zambia MindSpark deployments use **Ubiquiti UniFi U7 Lite** Access Points configured in **bridge/AP mode** (no NAT, no routing). The AP has a static management IP outside the DHCP pool and the MindSpark server acts as the sole DHCP provider for the entire subnet.

A static DHCP reservation for the AP ensures:
- The AP management UI is always reachable at a predictable IP.
- Lease conflicts with client devices are eliminated.
- Remote support via AnyDesk remains reliable regardless of reboot order.

### Auto-detection during setup

During Phase 3.6 the script:
1. Installs `arping` if not already present.
2. Performs a rate-limited ARP sweep across all 254 addresses in the configured subnet.
3. Reads the ARP table to identify the AP (the only non-server device present on the wired interface before learner devices connect).
4. Writes a `reservations` block into `/etc/kea/kea-dhcp4.conf` and restarts Kea.

If the AP is not detected within 60 seconds (e.g. it is powered off during setup), the script continues without a reservation. The reservation can be added manually at any time — see below.

### Manually updating the AP MAC reservation after setup

**Step 1 — Find the AP's MAC address**

```bash
# Trigger an ARP probe toward the AP's management IP (replace interface and IP as needed)
sudo arping -c 3 -I eth0 192.168.1.2

# Or check the ARP table after the AP has been online for a moment
ip neigh show dev eth0
arp -n
```

The UniFi U7 Lite MAC address will appear in the output in the format `aa:bb:cc:dd:ee:ff`. It can also be found on the label on the underside of the AP unit.

**Step 2 — Edit the Kea configuration**

```bash
sudo nano /etc/kea/kea-dhcp4.conf
```

Locate the `"reservations"` array inside the subnet block and add or update the entry:

```json
"reservations": [
    {
        "hw-address": "aa:bb:cc:dd:ee:ff",
        "ip-address": "192.168.1.2",
        "hostname": "mindspark-ap"
    }
]
```

**Step 3 — Validate and reload**

```bash
# Validate the config (dry-run, no service disruption)
sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf

# Apply the change
sudo systemctl restart kea-dhcp4-server   # Ubuntu 20.04
sudo systemctl restart kea-dhcp4          # Ubuntu 24.04
```

---

## Checking DHCP service status

### Service health

```bash
sudo systemctl status kea-dhcp4-server   # Ubuntu 20.04
sudo systemctl status kea-dhcp4          # Ubuntu 24.04
```

### Quick active check (works on both versions)

```bash
systemctl is-active kea-dhcp4-server kea-dhcp4 2>/dev/null
```

### View active leases

```bash
# Full lease table — all devices that have received an IP
cat /var/lib/kea/dhcp4.leases

# Count of active leases
grep -c '"ip-address"' /var/lib/kea/dhcp4.leases 2>/dev/null || echo "No leases yet"
```

### View DHCP logs

```bash
sudo journalctl -u kea-dhcp4-server -n 50 --no-pager   # Ubuntu 20.04
sudo journalctl -u kea-dhcp4 -n 50 --no-pager          # Ubuntu 24.04
```

---

## Testing policy

- All development and initial testing is performed on the **spare/test server** — no learner data.
- Production deployment occurs only during **approved downtime windows**.

---

## Repository structure

```
.
├── README.md
├── mindspark_setup.sh          # Main post-installation script
├── offline-packages/           # Bundled .deb packages (planned — offline support)
├── configs/
│   ├── netplan-template.yaml   # Netplan static-IP template
│   └── dhcpd.conf.template     # DHCP config reference template
└── docs/
    └── ap-standard.md          # Access Point standardisation guide
```

---

## Contributing

1. Create a feature branch from `main`.
2. Test all changes on the spare/test server before merging.
3. Open a pull request with a clear description of what changed and why.

---

## License

Internal use only — Edulution Africa.
