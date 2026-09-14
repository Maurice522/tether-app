# Custom LAN File-Sharing App — Developer Plan
## Mac + Windows + Android, same-network instant transfer

**Goal:** A single app/protocol you control, installed on all three platforms, that discovers devices on the same Wi-Fi and sends files instantly. No Apple protocol involved — you own the whole stack, so nothing breaks on OS updates.

This is a much smaller project than the AirDrop-compatible version. No reverse engineering, no BLE peripheral-mode headaches, no proprietary handshake. Realistic solo-developer build: **2–4 weeks** for a solid v1.

---

## Architecture Overview

- **Discovery:** mDNS/DNS-SD (Bonjour-style) — every device broadcasts itself on the LAN (e.g., `_yourapp._tcp.local`) with its name and IP. All three platforms support this natively or via well-maintained libraries.
- **Transfer:** A local HTTP server on each device. Sending a file = POST to the target's local IP. No cloud, no internet dependency, no account system needed.
- **Security:** Since anyone on the same Wi-Fi could theoretically discover your service, add a simple pairing step (PIN code or QR scan shown on the receiving device) so transfers aren't silently auto-accepted from strangers on shared/public networks.
- **UI shell:** One codebase across Android, Windows, and macOS via Flutter — this covers all three targets you need now and iOS later if you ever want it.

This is close to reimplementing LocalSend's core idea — worth having your developer skim LocalSend's open-source repo for reference on the discovery/transfer flow, even though you're building your own.

---

## Phase 0 — Setup (1–2 days)
- [ ] Decide app name / service identifier (used in mDNS broadcast string).
- [ ] Set up Flutter dev environment targeting Android, Windows, and macOS.
- [ ] Set up a test LAN with at least one Mac, one Windows machine, one Android phone.

## Phase 1 — Discovery (2–4 days)
- [ ] Implement mDNS broadcast + browse on all three platforms (Flutter packages exist for this — `multicast_dns` or `nsd` are common choices; developer should evaluate current maintenance status).
- [ ] Each device broadcasts: device name, platform icon, local IP, port.
- [ ] Build a simple "Nearby Devices" list screen showing everything found on the network.

## Phase 2 — Transfer Protocol (3–5 days)
- [ ] Each device runs a lightweight local HTTP server (e.g., using `shelf` in Dart/Flutter, or a native equivalent per platform if needed).
- [ ] Sending: pick file → POST multipart request to target device's IP:port.
- [ ] Receiving: incoming request triggers a prompt — Accept/Decline, with sender name and file preview (name, size, type).
- [ ] Handle large files with chunked transfer and a progress bar; handle multiple simultaneous files.

## Phase 3 — Pairing / Trust (2–3 days)
- [ ] On first contact between two devices, show a PIN or QR code the user confirms on both ends — avoids sending files to/accepting from unintended devices on shared networks (cafes, offices).
- [ ] Option to mark a device "trusted" so future transfers between the same two devices skip the prompt (still require accept for actual files unless auto-accept is explicitly enabled).

## Phase 4 — App Shell & Polish (3–5 days)
- [ ] Transfer history log.
- [ ] Settings: device name, download folder, auto-accept toggle, dark/light theme.
- [ ] Platform-specific packaging: `.apk`/Play-store-ready build for Android, `.exe`/MSIX for Windows, `.dmg`/`.app` for macOS.
- [ ] Basic error handling: device goes offline mid-transfer, duplicate filenames, insufficient storage.

## Phase 5 — Testing (2–3 days)
- [ ] Test every direction: Mac↔Windows, Mac↔Android, Windows↔Android.
- [ ] Test on different router setups (home router, guest network with client isolation — note: client isolation will block this entirely, since it prevents devices from seeing each other on the LAN; flag this as a known limitation).
- [ ] Large file stress test (video files, multi-GB).

---

## Rough Timeline

| Phase | Duration |
|---|---|
| 0: Setup | 1–2 days |
| 1: Discovery | 2–4 days |
| 2: Transfer | 3–5 days |
| 3: Pairing/Trust | 2–3 days |
| 4: App shell/polish | 3–5 days |
| 5: Testing | 2–3 days |

**Total: roughly 2–4 weeks for one developer.**

---

## Why This Is Easier Than the AirDrop-Compatible Route

- No proprietary protocol to reverse-engineer — you define the message format.
- No BLE peripheral-mode hardware concerns — mDNS over Wi-Fi works on all target platforms without special hardware checks.
- Nothing to break on iOS/macOS/Windows/Android updates, since you're not depending on Apple's undocumented internals — only on standard mDNS/HTTP, which are stable, documented protocols.
- No maintenance burden chasing Apple's changes — this is a "build once, it keeps working" project, unlike the AirDrop-compatible version.

## Known Limitations to Set Expectations On

- Devices must be on the same LAN/Wi-Fi (or a network that allows local device discovery — some public/guest Wi-Fi networks block this via client isolation).
- No internet-based/remote transfer in this version (out of scope, but note it if you might want it later — would need a relay server and a different architecture).
- If you later want iPhone included, the same Flutter codebase can target iOS with minimal extra work, since the protocol here is fully custom and not Apple-specific.
