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
  `util/pairing_code.dart`, `POST /pair`) — pairing is a deliberate,
  one-time step separate from sending: tapping **Pair** on a device sends
  a pair request with a 6-digit code, shown on both screens for a human
  to visually confirm before accepting. Once paired, that device is
  trusted permanently (each side keeps its own trust list; trust is never
  asserted by the *other* side over the wire — a compromised sender
  claiming "trust me" is not honored). Paired devices skip *all* prompts
  on every future transfer, in both directions — no code, no accept
  dialog, nothing. Unpaired devices still get a one-off **Send** with an
  inline pairing code and an accept/decline prompt, for occasional
  transfers without formally pairing.
- **App shell** (`lib/screens/`) — Nearby Devices list with per-device
  Pair/Send and a manual refresh (re-announces immediately instead of
  waiting for the next broadcast tick), an Activity tab (active transfers
  + persisted history, each completed incoming item has a "show in
  folder" action that reveals the exact saved file), and Settings (device
  name with an explicit Save button, download folder, theme, clipboard
  sync, paired device management).
- **Remote browsing** (`lib/screens/browse_screen.dart`,
  `remote_folder_screen.dart`, `GET /browse`, `GET /fetch`) — a new
  **Browse** tab lets you open a paired, currently-online device's shared
  folder (the same folder its incoming transfers are saved into),
  navigate into subfolders, and pull any file straight into your own
  shared folder — no per-file prompt, since pairing already established
  the trust. Deliberately scoped to that one folder rather than the whole
  filesystem: a sandboxed macOS build has no broader file access without
  the user granting it per-folder, and a fixed root keeps this feature's
  blast radius obvious.
- **Clipboard sync** (`POST /clipboard`, `AppState._pollClipboard`) — pick
  one paired device in Settings and turn sync on to mirror clipboard text
  both ways, polled every 2s (plain Dart `Clipboard.getData`, not a native
  watcher plugin, so it behaves identically on all three platforms without
  more native code to build-test blind for Windows). **Android caveat**:
  Android 10+ blocks any backgrounded app from reading the system
  clipboard — a deliberate OS privacy rule, not a bug here. Confirmed on a
  real device: the app process and its receiver keep running fine in the
  background (a push from the other device is applied immediately, any
  time), but the periodic poll's read is silently blocked/stale the whole
  time LAN Share isn't focused, so it can't detect a copy made while
  backgrounded no matter how often it ticks. `AppState` observes app
  lifecycle and forces one immediate check on resume, so switching back
  to LAN Share (not a full close/reopen) is enough to pick up and push
  whatever was copied while it was in the background.
- **Background survival on Android** (`android/app/src/main/kotlin/.../LanShareForegroundService.kt`,
  started from `MainActivity.onCreate`) — without this, Android froze the
  whole process (discovery, the transfer server, everything) shortly
  after the app was backgrounded, which is why devices "disconnected"
  and clipboard sync stopped even though nothing in the Dart code had
  changed. A minimal foreground service (no Dart/background-isolate work
  of its own — it only exists to hold foreground-service privilege) now
  keeps the process alive while backgrounded, with a persistent low-
  priority notification ("LAN Share is running") as the unavoidable
  visible side effect Android requires for this. Requests
  `POST_NOTIFICATIONS` at launch on Android 13+. Uses the `dataSync`
  foreground service type, which Android 15+ caps at ~6 cumulative hours
  while unplugged — long enough for normal use, but a very long
  background stretch on a new device could still eventually disconnect;
  not yet confirmed on a real device since this repo has no attached
  Android hardware to test against live.
- **Background/tray on desktop** (`lib/services/desktop_window_service.dart`,
  `window_manager` + `tray_manager`) — on macOS and Windows, closing the
  window hides it instead of quitting the app; a tray/menu-bar icon
  offers "Show LAN Share" and "Quit". This keeps the transfer server and
  discovery broadcast running so other devices can keep reaching you
  after you close the window — only Quit (from the tray menu, or the
  system's own app-quit shortcut) actually exits. No-op on Android/iOS.
  An incoming transfer or pair request also brings the window to the
  front automatically, so the prompt isn't missed behind other windows.

Verified so far: `flutter analyze`/`flutter test` pass; `flutter build
macos --debug` builds and the app launches/runs stably; `flutter build apk
--debug` builds cleanly. The background/tray service registers with macOS
without errors (confirmed via system logs — the status item scene is
created successfully), but its on-screen appearance hasn't been visually
confirmed in this dev environment; please confirm the tray icon shows up
and that closing the window keeps the app running when you test it. Not
yet run on an actual Android device/emulator or on Windows at all (see
Toolchain below).

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
- `POST /pair` — body: `{"id","name","code"}`. Same accept/decline
  response shape as `/offer`. Accepting always trusts the requester on
  both sides; nothing is transferred as part of pairing itself.
- `GET /browse?requesterId=<id>&path=<relative>` — lists the immediate
  children of `path` ("" for the root) in the shared folder, as a JSON
  array of `{"name","isDir","size","modified"}`. `403` if `requesterId`
  isn't paired.
- `GET /fetch?requesterId=<id>&path=<relative>` — streams one file's raw
  bytes from the shared folder. Same trust check as `/browse`.
- `POST /clipboard` — body: `{"requesterId","text"}`. Applies `text` to
  the local clipboard if `requesterId` is paired; otherwise `403`.

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
output — no custom native code was added. Most plugins in use
(`path_provider`, `shared_preferences`, `file_picker`, `provider`,
`uuid`, `intl`) resolve to a pure-Dart/FFI (`win32` package)
implementation on Windows, but `window_manager` and `tray_manager` (added
for the background/tray feature) *do* have real native C++ Windows
implementations — see `windows/flutter/generated_plugins.cmake` — so a
Windows build will actually compile native plugin code the first time,
which is exactly what the Visual Studio C++ workload below is for. To
actually build it:

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
