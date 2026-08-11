# DreamPlayer

A cross-platform video player built with Flutter.

## Goal

A video player app supporting:
- **Android** (primary, tested on user's Android phone — CPH2573, Android 16) and **iOS/iPad** (user's iPad Pro M2)
- **All audio codecs**: DTS, DTS-HD, E-AC3, AC3, TrueHD, etc.
- **Dolby Vision** where the display supports it
- **FFmpeg-based** decoding engine

## Current status

- App **UI skeleton** done (library, player, settings; dark theme).
- **HDR / codec on-screen display** done (Dolby Vision, HDR10+, HDR10, SDR; E-AC3, DTS-HD, TrueHD, AAC, ...).
- **Responsive layout** — no overflow on phones/tablets/landscape/large text.
- **Native refresh rate** selected at startup (verified 120 Hz on device).
- **DOLBY VISION PLAYBACK WORKS on Android via ExoPlayer/Media3 PlatformView.**
  Verified on-device: the DV P8 test file (`dolby-vision-people`) decodes on the
  Qualcomm hardware **`c2.qti.dv.decoder`** at 4K 3840x2160@60 fps with zero
  dropped frames, correct colors (no mpv pink/green), audio via
  `c2.dolby.eac3.decoder` / Media3 `FFmpegAudioRenderer`. Implementation:
  native `SurfaceView` PlayerView in a Flutter `AndroidView` (hybrid-composition
  fallback keeps its own SurfaceFlinger layer → real HDR to the display) +
  `MethodChannel`/`EventChannel` per view. `ExoPlayerController.open()` issued
  before the platform view attaches is queued and flushed in `_attach`.
  **Gotcha fixed:** the backend must `setState` after creating the controller,
  or the buttons/video layer stay frozen in the pre-init state.
- **media_kit / libmpv fully REMOVED** from `pubspec.yaml`, `main.dart`,
  `player_screen.dart`, and the APK (no more `libmpv.so`/mediakit libs; only
  `libflutter.so` + `libmedia3ext.so` remain). Non-Android screens show a
  "not yet supported" message until the iOS AVPlayer path lands.
- **New direction**: playback on Android via **ExoPlayer/Media3** in a Flutter
  **PlatformView + MethodChannel** (HDR/DV-capable native surface), modeled on
  **Nova Video Player** architecture. Keep the Flutter UI/shell, the rendering/
  decoding layer is native Android code.

## Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Flutter (stable, 3.44.x) | Cross-platform, single codebase |
| Playback engine (Android) | **ExoPlayer / Media3** (native, in PlatformView) | HDR/DV passthrough-capable; working (`c2.qti.dv.decoder`). |
| Android audio decode | Media3 `FFmpegAudioRenderer` (ffmpeg extension) | DTS, DTS-HD, E-AC3, AC3, TrueHD — same bundled-FFmpeg approach Nova uses. |
| Reference architecture | **Nova Video Player** (`nova-video-player/aos-AVP`) | See "Playback research notes". |
| ~~media_kit / libmpv~~ | **retired** | Cannot do Dolby Vision (no passthrough, no RPU). |
| Permissions | `permission_handler` | Runtime `READ_MEDIA_VIDEO` request on video open |
| Refresh rate | `flutter_displaymode` | Selects highest refresh mode at startup |

### Device research notes (user's Android phone)
- Display: 1440x3168, supports 60/90/120 Hz, max luminance ~1400 nits.
- `supportedHdrTypes=[1, 2, 3, 4]` → **HDR10, HDR10+, Dolby Vision, HLG** all supported on the panel. Good news for the Dolby Vision goal.
- The phone runs at 60 Hz when the UI is idle and jumps to 120 Hz during animations (adaptive). Verified via `dumpsys SurfaceFlinger` after app launch.

### Playback research notes
- **`media_kit`/mpv is dead for this project's DV goal.** On-device verification:
  - HDR10 (PQ/BT.2020) tone-maps to SDR correctly via mpv `gpu` vo.
  - Dolby Vision P8 renders **pink/green**: mpv v0.36 + FFmpeg 6.0 cannot parse the
    DOVI RPU (file VUI reports `color_transfer/primaries=unknown`), so wrong colors.
    `gpu-next` vo is a frozen frame (media_kit renders via legacy `gpu` path; mpv
    PR #16818 pending). `hwdec:no` (software) gives correct colors but is too slow
    for 4K.
  - Flutter textures (what media_kit uses) have **no HDR path on any platform**
    (media-kit issue #615) — the display only ever sees SDR.
- **New plan (ExoPlayer/Media3, Nova-style):**
  - Render video into a native Android `SurfaceView`/`SurfaceFlinger`-driven
    `PlatformView` so the display receives real HDR/DV signal (the panel supports
    DV — `supportedHdrTypes` includes it).
  - **Nova Video Player architecture** (`https://github.com/nova-video-player/aos-AVP`):
    entry-point repo with `default.xml` manifest. Sub-repos:
    - `aos-Video` — Video UI (Kotlin, ExoPlayer-based playback)
    - `aos-MediaLib` — media library / MediaStore scanning
    - `aos-FileCoreLibrary` — file management (root/network)
    - `aos-avos` — C core multimedia engine using FFmpeg (probing/decoding)
    - Uses ExoPlayer (`exoplayer.xml`) + FFmpeg audio extension for the lossless
      codecs. Building: `cd Video && ./gradlew -Puniversal assembleNoamazonRelease`
  - Android audio codecs map to Media3 `FFmpegAudioRenderer` extension modules;
    `dts`, `truehd`, `eac3`, `ac3` etc. are FFmpeg decoders.
- **Nova buffering / read-ahead (how Nova smooths slow SMB/Wi-Fi; source = `aos-avos`)**:
  - **48 MB ring buffer for network streams** — `Source/avos_mp_video.c:256`
    `stream_set_buffer_size(video->s, 48)`. Wiki "Buffering" history: 12→24 MB
    (2015, high-bitrate 4K) → 48 MB (2022, 2× speed). "Used as cache before the
    parser to tackle buffering issues." Local default is `STREAM_DEFAULT_BUFFER_SIZE`
    64 MB / `STREAM_LARGE_BUFFER_SIZE` 128 MB (`Include/stream.h:41-42`).
  - **Ring buffer + dedicated background pthread** — `Source/stream_buffer.c:162`
    `_buffer_thread` loops `pthread_mutex_trylock` → `buffer->buffer(buffer,1)`,
    sleeps 500 ms when full (`BUFFER_SLEEP`). It refills when the parsed-ahead
    media drops below `stream_drive_wake_sleep = 5000` (5 s, `stream_buffer.c:37`);
    when actively playing it uses `stream_drive_wake_no_sleep = 2000` (s) — i.e.
    keep the ring essentially **always full**.
  - **Rate-aware refill threshold** — `_calc_buffer_threshold` (`stream_buffer.c:55`)
    predicts seconds-ahead from the measured `vcurrent_rate`/`acurrent_rate`
    (min rate floor 250 kbit/s), not just free space. This informed the in-app
    SMB read-ahead design (see "SMB / network shares" roadmap section).
  - **Debugging**: `av.sh smb` prints the current max buffer size; `av.sh dbgv 2`
    shows fill rate.
  - **SMB library**: Nova's SMBv2/3 support is via **jcifs-ng** (wiki "SMBv2 3",
    Apr 2020; earlier jcifs 1.3.19 was SMBv1-only) — **NOT smbj** (see Libraries
    table correction). Nova's C core has no SMB IO module (`stream_io_*.c` are all
    local); network files are opened by the Android app layer and fed to the engine.
  - iOS/iPad DV is restricted by Apple APIs — ExoPlayer/Media3 is Android-only;
    iOS will need a separate native path (AVPlayer). For now focus Android.

## Implemented features

- **HDR detection** (`lib/models/hdr_format.dart`, `lib/utils/codec_info.dart`): parses hints like `DV P8`, `HDR10+`, `HDR10` into a `HdrFormat` (incl. `HLG`); maps raw codec names (`dts_hd`, `eac3`, `truehd`, `aac`, ...) to display labels. Live detection from Media3 format info: DV track codecs (`dvhe`/`dvh1`/`dvav`), `colorTransfer` (6→HDR10, 7→HLG).
- **Real playback** (`lib/screens/player_screen.dart`): Android uses a native **ExoPlayer/Media3 PlatformView** (`lib/services/exo_player.dart`) with live codec/HDR/resolution chips, play/pause, seek, ±10s, mute, fullscreen, buffering spinner, error surface. Non-Android shows a "not yet supported" message. Widget tests run playback-less (`FLUTTER_TEST` gate).
- **Android permissions**: `READ_MEDIA_VIDEO` (+ `READ_EXTERNAL_STORAGE` ≤ API 32) requested at runtime via `permission_handler` when a video is opened. `compileSdk = 37` required by `permission_handler`.
- **Player overlay** shows HDR format + video/audio codec + resolution chips; library cards show an HDR badge + audio codec label.
  - **DV dedup**: for Dolby Vision the purple HDR chip already says "Dolby Vision", so the redundant video-codec chip is suppressed (no "Dolby Vision" twice).
  - **Chip layout**: landscape puts back button + title + chips in one `Wrap` on the same row; portrait shows title row, then chips `Wrap` below.
- **Player controls**: top bar (back + title) and a slim bottom bar (time + seekbar + audio/CC/tune/fullscreen) auto-hide after 3 s of playback (tap toggles them; kept visible while paused/buffering/dragging). **Center transport**: `replay_10` / big play-pause / `forward_10` float in a dark rounded pill in the middle of the screen, fading with the other controls. The bottom bar's background is a gradient mirroring the top bar (transparent → `black` 0.72), so both bars read at the same opacity. The player screen is **always immersive** (no system UI toggling during rotation — that fights the rotation animation and makes the video jitter); the bottom fullscreen button just forces landscape/portrait. Top-bar fullscreen button removed.
- **Audio track selection** (mute button replaced): the bottom bar's first button opens an "Audio tracks" bottom sheet listing every audio track from the native Media3 `currentTracks` (language · codec · channels · bitrate), with the active track check-marked. Picking a track calls `setAudioTrack` → native `TrackSelectionParameters` override → `onTracksChanged` re-emits → the top-bar audio chip (live codec + channel count) updates automatically. Native plumbing in `android/.../ExoPlayerView.kt` (`buildAudioTracks`, `selectAudioTrack`), pushed on every event as `audioTracks`/`selectedAudioTrack`; Dart model `ExoAudioTrack` in `lib/services/exo_player.dart`. Verified on-device: Sonic (DTS-HD MA + FLAC) switches DTS-HD → FLAC and the chip follows.
  - **Full track names**: the sheet prefers the container-provided track `label` (e.g. `DTS-HD MA 5.1`, `Commentary`) and appends the channel count unless the name already carries it; otherwise it composes `languageName(lang) · codec · channels`. `ExoAudioTrack` gained a `label` field; ISO-639 codes map to full English names via `languageName()` in `codec_info.dart`.
- **FLAC via FFmpeg + E-AC3 decoder workaround**: a custom `MediaCodecSelector` in `ExoPlayerView.kt` does two things: (1) returns no decoder for `audio/flac` so FLAC falls through to the bundled FFmpeg renderer — the platform MediaCodec FLAC decoder on some devices (incl. this OnePlus) allocates fixed 32 KiB input buffers and large FLAC frames (24-bit multichannel ~54 KiB) die with `DecoderInputBuffer$InsufficientCapacityException: Buffer too small`; (2) skips any `c2.dolby.eac3.decoder` for `audio/eac3`/`audio/eac3-joc` — on this OnePlus the codec2 resource manager repeatedly releases that hardware decoder as soon as it starts, so Media3's audio renderer spins in an endless re-init loop and **no AudioTrack is ever created (silent playback)**. With the Dolby component excluded, the AOSP software E-AC3 decoder is used and the renderer is stable. Verified on-device: Sonic FLAC plays continuously; an E-AC3 (Dolby Atmos, 5.1) track plays with an active AudioTrack (48 kHz, channelMask `0x3f`, no churn, no errors).
- **File browser (CX-Explorer style)** (`lib/screens/file_browser_screen.dart`): browse the whole device storage in-app and play any video without importing. Folder icon in the home app bar opens it. Android side (`android/.../FileBrowser.kt`, channel `dreamplayer/files`): `hasAllFilesAccess` / `openAllFilesAccessSettings` / `getStorageRoots` (internal + SD card) / `listDirectory` (folders then video files, sorted, with sizes). Requires **`MANAGE_EXTERNAL_STORAGE`** (All Files Access) on Android 11+ — the screen shows a "Grant access" button that opens the system settings and re-checks on app resume. Tapping a video builds a `VideoItem` and pushes `PlayerScreen`. Verified on-device: Internal storage → Download → video → Dolby Vision People plays with live HDR/codec chips.
- **"Open with" / file-explorer integration** (`AndroidManifest.xml` `ACTION_VIEW` intent-filters for `content`/`file` schemes + video MIME types incl. `video/*`, matroska, mpeg, ts, avi, wmv, octet-stream): tapping a video anywhere on the device now offers DreamPlayer. `MainActivity` resolves the intent (file path or `content://` URI + display name via `OpenableColumns`) and forwards it over the `dreamplayer/intent` channel (`getInitialIntent` on launch / `open` on `onNewIntent`); `lib/services/open_intent.dart` turns it into a `VideoItem` and pushes `PlayerScreen` via a global `appNavigatorKey` in `lib/app.dart`. `VideoItem` gained an optional `uri` (content URIs) with `path` now nullable; `ExoPlayerView` opens a raw URI when no path is available. Verified on-device: "Open with" chooser lists DreamPlayer and launches Dolby Vision playback.
  - **CX Explorer network-stream handoff**: CX hands SMB videos to players as `http://127.0.0.1:<port>/SMB/...` (its own local HTTP proxy), so the intent filter additionally declares `http`/`https`/empty schemes (`<data android:scheme=""/>`) + the full container-MIME matrix (`video/x-matroska`, `application/octet-stream`, `application/mpeg`, ... — a single filter, since per-vendor MIMEs differ), and `android:usesCleartextTraffic="true"`. Media3's `DefaultDataSource` handles file/content/asset itself and sends every other scheme (http/https) to the base factory, so `ExoPlayerView.kt` wires `DefaultHttpDataSource.Factory()` as that base — CX's proxy streams arrive there with no fallback and no extra code. Verified on-device via logcat: 4K HEVC lossless (3840×2176@60) streamed through CX's proxy decoded at a steady 60 fps / **0 discarded frames** for a full session (`c2.qti.hevc.decoder` telemetry), only jank = the app's cold start.
- **Home/settings status bar**: `RootShell` maps `MediaQuery.viewPadding.top` into `padding` (Android edge-to-edge reports `padding.top == 0`), so `SliverAppBar` never overlaps the status bar.
- **Library emptied of sample data**: the home library no longer shows hardcoded demo videos — it starts empty with a "Your library is empty" empty-state (file browser and "Open with" are the way in) until a real MediaStore scan lands. The dead "Scan for videos" button was removed.
- **Responsive grid** (`lib/screens/home_screen.dart`): column count and card height computed from screen width; card text is `Expanded`/`Flexible`. Text scaling clamped to 1.3x app-wide.
- **Native refresh rate** (`lib/services/display_refresh_rate.dart`): calls `FlutterDisplayMode.setHighRefreshRate()` on Android at startup.
- **In-app SMB / LAN playback: REMOVED (2026-08)**. The in-app SMB server browser (`smb_screen.dart`, `smb_client.dart`, `SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, jcifs-ng) was deleted from the app — the user's day-to-day workflow plays NAS files via **CX Explorer's network share → "Open with" → DreamPlayer**, which streams over CX's local HTTP proxy at full speed (see the CX handoff note above). The SMB implementation knowledge (buffering, jcifs-ng tuning, discovery, subtitles) is preserved in the roadmap section below for future development. **Lesson learned on-device**: jcifs-ng's streaming read size is bound by three interlocking properties (`snd_buf_size`/`rcv_buf_size`/`transaction_buf_size`, defaults 65535); raising only the first two did nothing (still ~64 KB reads / ~5 MB/s with constant ring-buffer stalls), and raising `transaction_buf_size` to 8 MiB made the NAS reject reads with `STATUS_INVALID_PARAMETER` ("The parameter is incorrect"); 1 MiB was still rejected. Do not raise buffers past what the NAS's negotiated `MaxReadSize` accepts.
- Tests: 37 (`flutter test`) incl. no-overflow checks on small phone, tablet, landscape, and 2.0x text scale.

## Roadmap

### SMB / network shares (Android + iPad)

Play files from LAN/NAS SMB shares in-app, mirroring the existing file-browser pattern.

**Status: deferred (2026-08).** An in-app SMB v1 (browse + stream) was implemented and
verified against the real NAS, then **removed from the app** — the user's workflow is
CX Explorer's network share → "Open with" → DreamPlayer (streams over CX's local HTTP
proxy at full speed; no in-app SMB needed). If in-app SMB returns, the knowledge below
is the complete blueprint; the v1 was essentially done and only needed polish.

**Architecture**
- New native module per platform exposing a MethodChannel (same shape as `FileBrowser.kt` / `dreamplayer/files`):
  - Android: `SMBClient.kt` — channel `dreamplayer/smb`
  - iOS/iPad: `SMBClient.swift` — same channel
- Dart: `lib/services/smb_client.dart` (models + channel wrapper) + `lib/screens/smb_screen.dart` (server list → shares → folders → tap video → `PlayerScreen`).
- Playback passes an `smb://` URI through the existing `uri` path in `VideoItem` (like the "Open with" flow).

**Libraries**
| Platform | Choice | Why |
|---|---|---|
| Android | **jcifs-ng** (SMB2/3 only) | Nova's and CX File Explorer's SMB library; measured ~75 MB/s vs ~4–6 MB/s for smbj on the NAS. |
| Android (optional) | jcifs-ng SMB1 | SMB1 legacy devices only (disabled by default; SMB1 support is behind a config flag) |
| iPad | **AMSMB2** / **SwiftSMB** (Swift wrapper over **libsmb2**, C) | Only mature SMB2/3 path on iOS; libsmb2 is a serious candidate (Nova has discussed it) |
- **Licensing**: libsmb2 is LGPL-2.1 (constrains App Store distribution — needs relinkable/replaceable lib); app already ships GPLv3 FFmpeg extension so not a new concern for Android.

**Features**
1. *Servers*: add/edit/delete saved servers (name, host/IP, port 445, user, password, or Guest); credentials in Keychain (iOS) / Android Keystore (EncryptedSharedPreferences), never plaintext; LAN auto-discovery (broadcast/workgroup) + manual IP fallback; test connection + quick connect; saved-server status dot (online/offline).
2. *Browsing* (CX-Explorer style): server → shares → folders → files; breadcrumbs + up-nav; folders first, sorted by name/size/date; show size + modified date; player back returns to same folder.
3. *Playback*: direct streaming (no download) — Android = custom ExoPlayer `DataSource` over jcifs-ng seekable reads; iPad = `AVAssetResourceLoaderDelegate` serving bytes from the SMB stream; full seek; existing live HDR/codec chips unchanged; play-next-episode in folder; optional prefetch/cache-ahead setting + reconnect-on-drop/resume for high-bitrate files.
4. *Extras*: auto-pair subtitles from same folder (`.srt`/`.ass`); pin recently-used servers on home screen; DNS/WINS hostname resolution for NAS names.
- **Scope (v1)**: manual server add + Guest/basic auth + browse + stream + play-next. Add discovery + subtitles after.
- **Status**: v1 core landed (Android): discovery, status dots, play-next-episode and subtitle auto-pair are implemented and the app is running on-device; the Nova-style read-ahead ring buffer is implemented but **not yet verified against a real NAS**. Remaining: **full NAS verify of streaming/seek + subtitles + play-next** (share browsing is verified), reconnect-on-drop/resume for high bitrates, and the iPad path (needs AVPlayer first).
- **Note**: iPad playback requires the AVPlayer path first (non-Android currently shows "not yet supported") — SMB-on-iPad lands with it.

## CI / Deployment

- **iOS builds happen in GitHub Actions** (user has no Mac). Workflow: `.github/workflows/ios.yml`
  - Runs on `macos-latest`, builds unsigned IPA artifact always.
  - Signed build + TestFlight upload run only when secrets are configured.
  - Secrets needed: `IOS_CERT_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `APPSTORE_API_KEY`, `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID`.
- **Bundle ID (iOS)**: `com.dreamplayer.app`. **App display name**: `DreamPlayer`.
- **Android**: app label `DreamPlayer`; package `com.dreamplayer.app` (matches iOS bundle ID `com.dreamplayer.app`). Build/test locally on the phone.

## Repository / Git

- Remote: `https://github.com/mangeshghodke/DreamPlayer.git`
- Branch: `main`
- Never commit secrets.

## Commands

```bash
flutter pub get          # fetch dependencies
flutter analyze          # static analysis
flutter test             # run tests
flutter run              # run on connected Android phone (USB debugging)
flutter run --release    # test real-world smoothness (debug is jankier)
flutter build apk --debug --target-platform android-arm64 && flutter install --debug -d <device-id>
flutter build apk        # release APK (use --split-per-abi)
flutter build appbundle  # for Play Store
adb shell monkey -p com.dreamplayer.app -c android.intent.category.LAUNCHER 1   # launch app
adb shell dumpsys SurfaceFlinger | grep -a activeMode                                  # check refresh rate
```

## Display & smoothness (native refresh rate)

- **Android**: `flutter_displaymode` selects the display's highest refresh rate at app startup (`lib/services/display_refresh_rate.dart`). Many Android devices default apps to 60 Hz even on 90/120/144 Hz panels. Verified: panel runs 120 Hz during animations, 60 Hz when idle.
- **iOS/iPad Pro**: ProMotion 120 Hz is unlocked via `CADisableMinimumFrameDurationOnPhone = true` in `ios/Runner/Info.plist` (already set).
- **Playback cadence**: ExoPlayer renders at the video's FPS onto the platform-view SurfaceView. Revisit frame pacing once smoothness is assessed on-device.

## Project layout

```
lib/
  main.dart                     # entry point (native refresh rate, runs app)
  app.dart                      # root MaterialApp, dark theme, text-scale clamp, nav shell
  theme/app_theme.dart          # colors, dark theme (video apps are dark)
  models/
    video_item.dart             # VideoItem + codec label getters
    hdr_format.dart             # HdrFormat enum (SDR/HDR10/HDR10+/DV/HLG)
  utils/codec_info.dart         # HDR detection + codec -> label mapping + live label merge
  services/display_refresh_rate.dart  # high refresh rate selection (Android)
  services/exo_player.dart        # ExoPlayerController + ExoPlayerView platform view
  screens/
    home_screen.dart            # library grid (adaptive columns, empty state until scanning lands)
    player_screen.dart          # ExoPlayer/Media3 playback + live codec/HDR chips + controls
    settings_screen.dart        # settings list
  widgets/
    video_card.dart             # library card with HDR/audio badges
    format_chip.dart            # colored codec/HDR chip
test/
  widget_test.dart              # shell/navigation/overflow tests
  codec_info_test.dart          # HDR + codec formatting unit tests
```

## Workflow for the user (no Mac)

1. Develop + test on Android phone (USB debugging, `flutter run`).
2. Commit/push to `main`; iOS workflow in GitHub Actions builds the iPad version.
3. Later: configure code-signing secrets + TestFlight for installing on iPad Pro M2.
