# LAN Share

A custom cross-platform (macOS, Windows, Android) file-sharing app for your
own LAN. No cloud, no accounts — devices discover each other over UDP
broadcast and transfer files directly over HTTP.

See [`custom-lan-file-share-dev-plan.md`](custom-lan-file-share-dev-plan.md)
for the original phased plan this implements.

## Status

Implemented (Phases 1–4 core logic):

- **Discovery** (`lib/services/discovery_service.dart`) — devices announce
  themselves every 3s via UDP broadcast on port `57891` and are dropped
  after ~11s of silence. Deliberately *not* mDNS/Bonjour: a hand-rolled
  broadcast keeps behavior identical across macOS/Windows/Android without
  depending on per-platform plugin support (Windows mDNS plugin support is
  the usual weak point).
- **Transfer protocol** (`lib/services/transfer_server.dart`,
  `transfer_client.dart`) — each device runs an HTTP server on an
  OS-assigned port (broadcast alongside its discovery announce).
  `POST /offer` sends file metadata and blocks (holding the connection
  open) until the receiving user accepts or declines, or 60s elapses.
  Accepted files are streamed one at a time via
  `POST /upload/<transferId>/<fileIndex>` straight to disk — never fully
  buffered in memory — with progress reported as bytes flow.
- **Pairing/trust** (`lib/services/pairing_store.dart`,
  `util/pairing_code.dart`) — first contact with an untrusted device shows
  a 6-digit code in both the sender's "waiting" screen and the receiver's
  accept dialog, so a human can visually confirm both devices agree before
  accepting. Each device keeps its own trust list; trust is never asserted
  by the *other* side over the wire (a compromised sender claiming "trust
  me" is not honored — the receiver's own trust store is authoritative for
  its side, and vice versa). Auto-accept for trusted devices is an
  explicit opt-in setting, per the original plan.
- **App shell** (`lib/screens/`) — Nearby Devices list with per-device
  Send, an Activity tab (active transfers + persisted history), and
  Settings (device name, download folder, auto-accept, theme, trusted
  device management).

Not yet done (see original plan's Phase 4/5):

- Platform packaging (`.apk`, MSIX, `.dmg`) — needs full Xcode / Android
  SDK, see below.
- Cancel-in-progress / resume support.
- Real multi-device testing across Mac/Windows/Android (Phase 5) — needs
  the toolchains below installed and a live LAN with all three devices.

## Wire protocol

**Discovery** — UDP broadcast, port `57891`, JSON payloads:

```json
{"v":1,"type":"announce","id":"<uuid>","name":"Maurice's MacBook","platform":"macos","port":54213}
{"v":1,"type":"bye","id":"<uuid>"}
```

**Transfer** — plain HTTP on the port from the announce:

- `POST /offer` — body: `{"transferId","senderId","senderName","files":[{"name","size"}],"pairingCode"}`.
  Response (after the receiving user decides, or on timeout):
  `{"decision":"accept"}` or `{"decision":"decline"}`.
- `POST /upload/<transferId>/<fileIndex>` — raw file bytes, one file per
  request, sent sequentially for a given transfer.

There's no TLS — this is intentionally a trusted-LAN tool, not something to
run over an untrusted network segment.

## Toolchain

Flutter is installed outside this repo, cloned from the stable channel:

```bash
export PATH="$HOME/development/flutter/bin:$PATH"   # already added to ~/.zshrc
flutter doctor
```

- **macOS builds** need full Xcode from the App Store (Command Line Tools
  alone can compile the native-asset FFI bits but not the app shell/xcodeproj
  build). After installing: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch`.
- **Android builds** need Android Studio / the Android SDK — see
  https://flutter.dev/to/macos-android-setup.
- **Windows builds** need to happen on a Windows machine (or you'll need
  Visual Studio's C++ desktop workload there) — Flutter's Windows desktop
  target isn't cross-compilable from macOS.

Once a platform's toolchain is present:

```bash
flutter run -d macos      # or windows, or a connected Android device
flutter analyze
flutter test
```

## Known limitations (from the original plan)

- Devices must be on the same LAN — client-isolated guest Wi-Fi will block
  discovery entirely.
- No internet/remote transfer — LAN only, by design.
- No TLS — don't run this on a network you don't trust.
