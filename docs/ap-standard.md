# Access Point Standardisation Guide

This document defines the baseline configuration for all MindSpark Access Points. The goal is to maintain consistent settings **regardless of AP brand**, so that swapping hardware causes minimal disruption.

## Core Settings

| Setting | Standard Value | Notes |
|---------|---------------|-------|
| **SSID** | `MindSpark` | Uniform across all sites |
| **Security** | WPA2-PSK (AES) | No TKIP; WPA3 where supported |
| **Channel width** | 20 MHz (2.4 GHz) / 40 MHz (5 GHz) | Avoids co-channel interference |
| **Channel** | Auto (or site-surveyed) | Document chosen channel per site |
| **DHCP** | Disabled on AP | Server handles DHCP via `isc-dhcp-server` |
| **Operating mode** | Access Point (bridged) | AP must NOT run its own NAT/routing |
| **AP IP address** | Static — within server subnet but **outside** DHCP range | e.g. `192.168.8.200` |
| **Gateway** | Points to the MindSpark server IP | e.g. `192.168.8.1` |
| **DNS** | Same as server DNS setting | e.g. `8.8.8.8` |

## Wireless best practices

1. **Disable band steering** unless the AP brand implements it reliably — most low-cost APs do not.
2. **Separate SSIDs per band** only if client devices have known compatibility issues; otherwise a single SSID is preferred for simplicity.
3. **TX power**: Set to the lowest level that still provides coverage in the classroom. Over-powered APs cause more interference than connectivity.
4. **Client isolation**: **Disabled** — learner devices need to reach the server.
5. **Firmware**: Keep up to date. Record firmware version in the site handover sheet.

## Management access

| Setting | Value |
|---------|-------|
| Admin username | *(set per site — do NOT leave as default)* |
| Admin password | *(set per site — strong, unique, recorded securely)* |
| Management VLAN | Same LAN (no VLANs unless site requires it) |
| Remote management | Disabled |

## When changing AP brand

1. Copy the settings from the table above into the new AP's interface.
2. Set the AP to **bridge / AP mode** (not router mode).
3. Assign a static IP outside the DHCP range.
4. Verify a client device:
   - Receives an IP from the MindSpark DHCP server.
   - Can reach the server's content pages.
5. Update the site handover sheet with the new AP model and firmware version.

## Site handover checklist

For each deployment, record:

- [ ] AP make & model
- [ ] Firmware version
- [ ] AP static IP
- [ ] Channel & band
- [ ] SSID confirmed as `MindSpark`
- [ ] Security set to WPA2-PSK (AES)
- [ ] DHCP on AP disabled
- [ ] Client connectivity verified
