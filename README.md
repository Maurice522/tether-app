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

Verified so far: `flutter analyze`/`flutter test` pass; `flutter build
macos --debug` builds and the app launches/runs stably; `flutter build apk
--debug` builds cleanly. Not yet run on an actual Android device/emulator
or on Windows at all (see Toolchain below).

Not yet done (see original plan's Phase 4/5):

- Release packaging (signed `.apk`/AAB, MSIX, `.dmg`) — debug builds work
  now; release signing configs aren't set up.
- Cancel-in-progress / resume support.
- Real multi-device testing across Mac/Windows/Android (Phase 5) — needs
  a Windows machine (can't be done from this Mac) and a live LAN with all
  three devices.

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

On this Mac, **macOS and Android are both fully set up and verified**:

- Xcode 26.6 installed (App Store) — `flutter build macos --debug` builds
  and the app launches and runs stably.
- Android SDK installed headlessly via command-line tools (no Android
  Studio GUI needed) — `~/Library/Android/sdk`, with platform 35/36 and
  build-tools 28.0.3/36.0.0 (Flutter wants specific versions of each).
  JDK 17 (Temurin) at `~/development/jdk-17`. Both `JAVA_HOME` and
  `ANDROID_HOME` are exported in `~/.zshrc`. `flutter build apk --debug`
  builds cleanly.
  - Note: `file_picker` had to be bumped from 8.x to 12.x — the old
    version's bundled Android module hardcoded `compileSdk 34`, which
    conflicted with a transitive dependency requiring 36+. The 12.x
    `FilePicker.pickFiles()`/`getDirectoryPath()` API is also slightly
    different (no more `.platform` singleton, `pickFiles` returns
    `List<PlatformFile>` directly) — already updated in
    `lib/screens/devices_screen.dart` and `settings_screen.dart`.

**Windows can't be built or tested from this Mac** — Flutter's Windows
desktop target requires an actual Windows host with Visual Studio's
"Desktop development with C++" workload; there's no cross-compilation
path. The `windows/` scaffold here is the untouched `flutter create`
output — no custom native code was added, and every plugin in use
(`path_provider`, `shared_preferences`, `file_picker`, `provider`,
`uuid`, `intl`) resolves to a pure-Dart/FFI (`win32` package)
implementation on Windows, i.e. `windows/flutter/generated_plugins.cmake`
has no native C++ plugin entries to go wrong. To actually build it:

1. On a Windows machine, install Flutter (same stable-channel clone
   approach works, or the installer from flutter.dev) and Visual Studio
   2022 Community with the "Desktop development with C++" workload.
2. Copy or `git clone` this repo there.
3. `flutter doctor` should show Visual Studio ✓, then:
   ```
   flutter run -d windows
   ```
4. Windows Defender Firewall will prompt to allow the app through on
   first run (for both the discovery UDP broadcast and the HTTP transfer
   server) — allow it on at least the Private network profile.

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
