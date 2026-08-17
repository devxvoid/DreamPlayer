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
  native `SurfaceView` PlayerView in a Flutter **hybrid-composition** platform
  view (`lib/services/exo_player.dart` `PlatformViewLink` +
  `PlatformViewsService.initExpensiveAndroidView`) so the SurfaceView is a real
  SurfaceFlinger layer on the physical display → real HDR to the display +
  `MethodChannel`/`EventChannel` per view. `ExoPlayerController.open()` issued
  before the platform view attaches is queued and flushed in `_attach`.
  **VIRTUAL-DISPLAY gotcha (2026-08, the REAL HDR blocker)**: the stock
  `AndroidView` widget has NO hybrid composition — it uses Flutter's
  **virtual-display + texture** pipeline (`TextureAndroidViewController`). The
  video's `SurfaceView` is composited into a non-HDR virtual display
  (`flutter-vd#1` in `dumpsys SurfaceFlinger`, max 500 nits, `HWC Support:
  dv=false`), read back as a texture, and that SDR-flattened buffer is what
  reaches the panel. Real HDR is physically impossible through that path — no
  amount of window color mode / headroom / dataspace forcing helps; the video
  layer reports `forceClientComposition=true clientType=UNSUPPORTDATASPACE`
  `whitePointNits=-1` and colors come out washed out. **Just Player (a pure
  native Activity) device-composites the same file (`forceClientComposition=false
  whitePointNits=1249.99`) — same decoder, same dataspace, same metadata.** The
  fix: render the platform view with hybrid composition (`PlatformViewLink` +
  `initExpensiveAndroidView`, i.e. HC). Verified on-device after the switch:
  `flutter-vd#1` gone, video layer `composition type=DEVICE`,
  `dataspace=BT2020_ITU_PQ` `hdr metadata types=9`, buffer format
  `Y_CBCR_420_TP10_UBWC` (10-bit PQ), display output `whitePointNits=1249.99`,
  display color mode `DISPLAY_P3` — byte-for-byte the Just Player profile, and
  colors match on screen. (Flutter HC is "expensive" (\> a view-composition
  host) but is the standard hybrid path; HCPP `initHybridAndroidView` needs
  Vulkan + API 34 and is not used.)
  **Gotcha fixed:** the backend must `setState` after creating the controller,
  or the buttons/video layer stay frozen in the pre-init state.
  **HDR10 passthrough re-verified alongside DV (2026-08)**: the HDR10 file
  (`Dolby-Core-Universe-Lossless-Uhd`, HEVC Main10/BT.2020/SMPTE ST 2084)
  decodes on `c2.qti.hevc.decoder` at 4K 3840x2112@24 fps with zero discard, and
  `dumpsys SurfaceFlinger` shows the DreamPlayer `SurfaceView` layer composited
  as `dataspace=BT2020_ITU_PQ` with `hdr metadata types=3` (HDR10 static + HDR10+
  dynamic), `forceClientComposition=true clientType=UNSUPPORTDATASPACE` (handed
  to the display, not GPU tone-mapped) and the display output layer fed
  BT2020_PQ at `dimmingRatio=1.0`. The DV P8 file likewise composites as
  `BT2020_PQ` with `hdr metadata types=8` (DV decoder outputs the base
  HDR10-compatible layer). Panel: `supportedHdrTypes=[1,2,3,4]`,
  `  mMaxLuminance=1400`. (The `IMAX_SONIC_ANTHEM` mkv is actually SDR h264/BT.709
  despite the name — its BT709 layer is correct.)
  **HDR EDR ramp engaged (2026-08, OnePlus)**: with the passthrough working, the
  display was STILL not boosting — bright PQ skies clipped flat to white.
  Root cause: OPLUS only enters HDR mode when the *window* asks for headroom.
  `ExoPlayerView.applyHdrHeadroom` now (1) sets `window.setDesiredHdrHeadroom(5.0)`
  for PQ/HLG content (incl. DV base layer) — the SurfaceView-layer API puts the
  ratio on the video layer where OPLUS ignores it for the EDR ramp; (2) switches
  the window to `ActivityInfo.COLOR_MODE_HDR` (OPLUS gates the headroom/EDR ramp
  on the window layer being in HDR color mode — Nova's dump shows DISPLAY_P3 +
  ratio, ours stayed V0_SRGB which is why headroom alone did nothing); (3) sets
  the video surface's dataspace CONSUMER-side via
  `SurfaceControl.Transaction.setDataSpace` (without it OPLUS HWC reports
  `UNSUPPORTDATASPACE` and SF falls back to client composition, which never
  engages the EDR boost — `current hdr/sdr ratio` stuck at 1.0). Verified
  on-device with the HDR10+ "lake" clip: `desired hdr/sdr ratio=5.0` on the
  window layer, SDR UI dimmed, video layer device-composited with the ratio
  ramping, no more white clipping. **DV-without-Colour-element gotcha (2026-08)**:
  some DV profile-7/8 MKVs omit the MKV `Colour` element — the PQ/BT.2020 info
  lives only in the HEVC SPS VUI (ffprobe parses it, Media3's MatroskaExtractor
  does not), so `player.videoFormat?.colorInfo` is `null` and the headroom
  decision used to fall to SDR (`desired ratio=1.0`) even though the SF video
  layer composites as `BT2020_ITU_PQ`. Fix: `stateMap` treats any
  `dvhe`/`dvh1`/`dvav` codec as HDR (DV is always HDR — profiles 4/7/8 base is
  PQ BT.2020, profile 5 is IPTPQc2), matching the Dart `detectMedia3HdrFormat`
  `dv`-prefix heuristic that already labels the chip correctly. Since the
  hybrid-composition switch (see the VIRTUAL-DISPLAY gotcha above), DV content
  *skips* the window HDR/headroom machinery entirely (`skipWindowHdr`) and
  device-composites with the decoder's native BT.2020 PQ dataspace — verified
  on-device (`dvhe.08.06` track): video layer `BT2020_ITU_PQ hdr metadata
  types=9`, `whitePointNits=1249.99`, display `DISPLAY_P3`, no forced dataspace
  or headroom needed. The `colorInfo=null` detection still matters only for the
  Dart HDR chip label.
  **API-gate gotcha (2026-08, Redmi Note 10 /
  MIUI API 31)**: the two-arg `SurfaceControl.Transaction.setDataSpace(
  SurfaceControl, Int)` overload is **API 33+** — the single-arg
  `setDataSpace(Int)` is API 29, and the target-surface overload does NOT exist
  on API 29-32. Guarding the block with `SDK_INT >= Q` still compiled and R8
  kept the call, so on Android 12 devices it crashed at open with
  `NoSuchMethodError: setDataSpace(Landroid/view/SurfaceControl;I)`. Guard the
  two-arg overload with `SDK_INT >= TIRAMISU` (same gate as
  `setDesiredHdrHeadroom`).
  **Non-DV / non-HDR devices (2026-08, Redmi Note 10 — HDR10 yes, DV no)**:
  three behaviors keep DV/HDR correct across phones:
  (1) **DV P7/P8 → HEVC fallback**: `mediaCodecSelector` in `ExoPlayerView.kt`
  returns `video/dolby-vision` decoder infos when a DV decoder exists, otherwise
  the **HEVC** (`MimeTypes.VIDEO_H265`) decoder infos — P7/P8 base layers ARE
  HDR10 HEVC, so on DV-less devices they play as HDR10 (verified on-device:
  `Dolby-Core-Universe-Lossless-Uhd` decodes via `qcom.decoder.hevc` with
  `setColorMode(2)` engaged). (2) **DV Profile 5 rejection**: P5 (IPTPQc2 color,
  streaming/web rips like `dolby-vision-people`, codec string `dvhe.05.<level>`)
  is NOT HDR10 HEVC and renders pink/green on any DV-less device — `emit()` calls
  `dvP5Rejection()` (lazy `MediaCodecList` check for `video/dolby-vision`;
  `dvRejectionShown` latch reset on `open()`) which `player.stop()`s and surfaces
  `error=UnsupportedDolbyVisionProfile5` → Dart `_friendlyError` shows "This
  device cannot decode Dolby Vision Profile 5…" (verified end-to-end on Redmi via
  uiautomator dump). (3) **SDR-only panels**: `applyHdrHeadroom` early-returns
  when `display.hdrCapabilities?.supportedHdrTypes` is empty — pushing an SDR
  panel into `COLOR_MODE_HDR`/PQ dataspace would break SurfaceFlinger's automatic
  HDR→SDR tone mapping (washed-out colors). `Display.isHdrSupported` is API 34;
  use `hdrCapabilities?.supportedHdrTypes?.isNotEmpty() != true` (API 24+), and
  note `HdrCapabilities` has no `isHdrSupported` in the android-37 stub.

- **iOS/iPad playback via AetherEngine (2026-08)** — the raw **AVPlayer**
  platform view was swapped for an **AetherEngine**-backed one
  (`ios/Runner/AvPlayerView.swift`, `UiKitView` on the Dart side) behind the
  exact same `dreamplayer/exo_<id>` method/event channel contract, so the Dart
  `ExoPlayerController` is unchanged. AetherEngine adds what AVPlayer alone
  cannot: **FFmpeg demux of MKV/TS/AVI/WebM**, **DTS/DTS-HD/TrueHD/E-AC3 audio**
  (AudioToolbox + libavcodec), **Dolby Vision / HDR10(+) via the native AVPlayer
  path** for Apple containers. `engine.bind(view:)` mounts `AetherPlayerView`
  (own `AVPlayerLayer` → real HDR where the panel supports it; iPad Pro M2
  does). Engine added as an SPM dependency (`project.pbxproj`, pinned
  `upToNextMajorVersion` from 6.21.0) — Xcode auto-resolves FFmpegBuild's
  dynamic FFmpeg xcframeworks into the app bundle. **CI-green** (run on commit
  `82b3dd9`). **Verified on-device (2026-08):** local/Documents files play on the iPad Pro M2;
  SMB playback was fully REMOVED (2026-08, see "SMB / network shares") — NAS files reach the app
  via CX/Files "Open with" (iPad) or in-app WebDAV/Jellyfin.
  **Minimum iOS 18.0** (`IPHONEOS_DEPLOYMENT_TARGET = 18.0`; builds for
  iOS 18 through the latest, iPhone and iPad).
  - Channel mapping: state 1/2/3/4 (idle/buffering/ready/ended); DV surfaces as
    `dvhe.<profile>.06` so Dart's `dv`-prefix detection fires; `colorTransfer`
    6 for HDR10/10+/DV, 7 for HLG. Audio/subtitle tracks pushed via
    `currentTracks`; `selectAudioTrack`/`selectSubtitleTrack`/`clearSubtitle`
    mapped 1:1 to engine calls.
  - **SMB fully removed (2026-08)**: the in-app iPad SMB browser (`SMBClient.swift`,
    channel `dreamplayer/smb`) and all `AvPlayerView` SMB paths (`smbToken`/
    `isSMBStream`/`reopenSMBStream`/`previousStaleSMBConnection`/
    `sniffFormatFromSMB`) were DELETED — slow, and it didn't play every video
    (the reopen/teardown audio-switch crash never came back but the entry was
    retired for good). NAS playback is via CX/Files "Open with" +
    bookmarked folders, in-app WebDAV, and in-app Jellyfin. `BufferedSMBReader.swift`
    STAYS — the WebDAV playback path (`WebDAVByteRangeSource`) still wraps it for
    read-ahead (32 MiB window / 4 MiB chunks; WebDAV keeps 4 MiB since one HTTP
    Range request ≈ one round-trip, unlike SMB's serial reads — the 256 KiB SMB
    chunk cap now applies only if SMB ever returns, see the roadmap).
    `AetherEngineSMB` product also STAYS in the Xcode project: WebDAV lives in
    that module (`ByteRangeSource` protocol + `WebDAVByteRangeSource`).
    CI will verify
    the iOS build.
  - **Replay / scrub-after-end**: AetherEngine's `.ended` is terminal (seek and
    play are explicit no-ops there), so `AvPlayerView` keeps the last-opened
    `url` + `LoadOptions` and a `play`/`seekTo` arriving in `.ended` reloads the
    session (`reloadSession(at:)` — start for replay, target for scrubber
    pull-back) instead of calling a no-op seek. The active subtitle track is
    re-applied after the reload.
  - **Subtitles render host-side**: AetherEngine decodes cues into
    `engine.$subtitleCues` and its `AetherPlayerView` does NOT paint them, so
    `AvPlayerView` draws its own `SubtitleOverlayView` (text + PGS/DVB bitmap
    cues positioned against the aspect-fit video rect; `zPosition = 1000` above
    the re-attached video layer). **Portrait PGS fix (2026-08)**: the
    `videoRect(in:)` aspect-fit branches were swapped, so in portrait it returned
    a ~2.5×-wide rect and bitmap cues rendered oversized/off-screen; now the
    view-wider-than-video case fills height (bars left/right) and the
    view-taller case fills width (bars top/bottom). `show(image:)` also maps the
    cue's normalized `position` through `SubtitleImage.canvasSize` (width-aligned,
    center-anchored) per the engine's contract, so cropped rips with a taller
    canvas than the video still land correctly. **Cue anchoring (2026-08)**: all
    positioning moved INTO `SubtitleOverlayView` (it keeps the current cue + the
    coded `videoSize`); `layoutSubviews` recomputes the aspect-fit video rect and
    repositions the active cue on every bounds change, so text AND bitmap cues hug
    the video's bottom edge and stay put through rotation — before, the text label
    was Auto-Layout-pinned to the overlay (screen) bottom, so it sat in the
    letterbox bar at the edge of the screen in both orientations. Text cues are
    centered on the video rect, bottom-anchored 12 pt above it, capped to the
    rect's width. Sibling sidecar files (SRT/ASS/
    VTT) auto-pair as `ExternalSubtitleTrack`s (best filename match `isDefault`,
    id = `externalSubtitleTrackIDBase` + ordinal) — like Android.
  - A Documents-folder file browser (`ios/Runner/FileBrowser.swift`, same
    `dreamplayer/files` contract) plus
    `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace` mean videos are
    dropped into the app via the Files app ("On My iPad → DreamPlayer") and
    played in-app. **iOS "Open with" works too** — `CFBundleDocumentTypes`
    (system video UTIs) + **`UTImportedTypeDeclarations`** (custom UTIs mapping
    `mkv`/`ts`/`m2ts`/`webm`/`wmv`/`flv`/`ogv`/`rmvb`/`mpg`/`vob`… to
    `public.movie`, since iOS has no system UTI for those containers) put
    DreamPlayer in the Files/share sheet for every container, and
    `ios/Runner/IntentBridge.swift` mirrors the Android `dreamplayer/intent`
    contract (`getInitialIntent` on launch via scene connection options /
    launch options; `open` from `application(_:open:options:)` +
    `scene(_:openURLContexts:)`, deduped). Security-scoped file URLs from the
    Files app keep their access scope for the playback session. Opening a file
    auto-plays it: the intent pushes `PlayerScreen`, whose `open()` runs with
    `autoplay: true`.
- **media_kit / libmpv fully REMOVED** from `pubspec.yaml`, `main.dart`,
  `player_screen.dart`, and the APK (no more `libmpv.so`/mediakit libs; only
  `libflutter.so` + `libmedia3ext.so` remain).
- **Subtitles done (embedded + sideloaded)**: every sibling subtitle file in
  the video's folder auto-attaches (SRT, SSA/ASS, WebVTT, TTML, SAMI, MicroDVD,
  MPL2, SubViewer via custom parsers), the best match auto-selects, and the CC
  button opens a full track picker over embedded + sideloaded tracks.
- **Static HDR10 detection for MKV files without Colour element (2026-08)**: some HEVC MKVs omit the MKV `Colour` element — the PQ/BT.2020 mastering metadata lives only in the HEVC SEI (payload types 137 Mastering Display Colour Volume, 144 Content Light Level). `ExoPlayerView.kt` now probes the first ~10 MB of video samples on a background thread with `MediaExtractor`, scanning Annex-B / AVCC NALs for these SEI payloads. When found, `hdr10Content=true` is set and `stateMap` emits `desired=5.0` + `colorTransfer=6`, engaging the HDR headroom / window color mode path for true HDR10 passthrough even without container-level signalling. Verified on-device: a test MKV with no Colour element but with SEI 137/144 now shows the HDR10 chip and triggers the EDR ramp.
- **New direction**: playback on Android via **ExoPlayer/Media3** in a Flutter
  **PlatformView + MethodChannel** (HDR/DV-capable native surface), modeled on
  **Nova Video Player** architecture. Keep the Flutter UI/shell, the rendering/
  decoding layer is native Android code.

## Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Flutter (stable, 3.44.x) | Cross-platform, single codebase |
| Playback engine (Android) | **ExoPlayer / Media3** (native, in hybrid-composition PlatformView) | HDR/DV passthrough-capable; working (`c2.qti.dv.decoder`). Hybrid composition (`PlatformViewLink`) keeps the video SurfaceView on the physical display — the stock `AndroidView` is virtual-display/texture and flattens HDR. |
| Playback engine (iOS/iPad) | **AetherEngine** (native, in PlatformView) | `AvPlayerView.swift` + `AetherEngine` SPM dep; FFmpeg demux/decode + native AVPlayer path for DV/HDR; cues drawn by host `SubtitleOverlayView`. |
| SMB client (iPad) | **removed (2026-08)** | In-app SMB (AMSMB2 browse + AetherEngineSMB playback) was retired; NAS playback is WebDAV / Jellyfin / Files-app "Open with". `AetherEngineSMB` still ships for WebDAV's `ByteRangeSource`. |
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

- **HDR detection** (`lib/models/hdr_format.dart`, `lib/utils/codec_info.dart`): parses hints like `DV P8`, `HDR10+`, `HDR10` into a `HdrFormat` (incl. `HLG`); maps raw codec names (`dts_hd`, `eac3`, `truehd`, `aac`, ...) to display labels. Live detection from Media3 format info: DV track codecs (`dvhe`/`dvh1`/`dvav`), `colorTransfer` (6→HDR10, 7→HLG). **HDR10+ is detected from the real bitstream** (2026-08): Media3's format info can't tell HDR10+ from HDR10 (both are PQ transfer 6), so `ExoPlayerView.kt` probes the first video samples with `MediaExtractor` for the ST 2094-40 SEI (ITU-T T.35 user data, country `0xB5` / provider `0x003C`, prefix/suffix SEI NAL types 39/40, AVCC + Annex-B handled) on a background thread and emits `isHdr10Plus` in the event map; Dart's `detectMedia3HdrFormat` upgrades to HDR10+ when set. `detectHdrFormat` filename-hint parsing is token-aware (safe on full titles — `Adventure.mkv` stays SDR) but the hint is **not** auto-wired from titles: the top-bar chip and labels reflect only what is actually in the content, so a misnamed file never gets an HDR chip. Probe is best-effort (failure → HDR10 label, playback unaffected); SDR content is never labeled HDR (verified on-device: lake `hdr10+...` file → amber HDR10+ chip via probe, SDR screen-recording → no chip). iOS AetherEngine has no equivalent probe yet — HDR10+ on iPad still labels as HDR10.
- **Real playback** (`lib/screens/player_screen.dart`): Android uses a native **ExoPlayer/Media3 PlatformView** in **hybrid composition** (`lib/services/exo_player.dart` — `PlatformViewLink` + `PlatformViewsService.initExpensiveAndroidView`; the stock `AndroidView` widget is virtual-display + texture and flattens HDR, see the VIRTUAL-DISPLAY gotcha in the top section) with live codec/HDR/resolution chips, play/pause, seek, ±10s, mute, fullscreen, buffering spinner, error surface. Non-Android shows a "not yet supported" message. Widget tests run playback-less (`FLUTTER_TEST` gate).
- **Android permissions**: `READ_MEDIA_VIDEO` (+ `READ_EXTERNAL_STORAGE` ≤ API 32) requested at runtime via `permission_handler` when a video is opened. `compileSdk = 37` required by `permission_handler`.
- **Player overlay** shows HDR format + video/audio codec + resolution chips; library cards show an HDR badge + audio codec label.
  - **DV dedup**: for Dolby Vision the purple HDR chip already says "Dolby Vision", so the redundant video-codec chip is suppressed (no "Dolby Vision" twice).
  - **Chip layout**: landscape puts back button + title + chips in one `Wrap` on the same row; portrait shows title row, then chips `Wrap` below.
- **Player controls**: top bar (back + title) and a slim bottom bar (time + seekbar + audio/CC/aspect/fullscreen) auto-hide after 3 s of playback (tap toggles them; kept visible while paused/buffering/dragging). **Center transport**: `replay_10` / big play-pause / `forward_10` float in a dark rounded pill in the middle of the screen, fading with the other controls. The bottom bar's background is a gradient mirroring the top bar (transparent → `black` 0.72), so both bars read at the same opacity. The player screen is **always immersive** (no system UI toggling during rotation — that fights the rotation animation and makes the video jitter); the bottom fullscreen button just forces landscape/portrait. Top-bar fullscreen button removed.
- **Aspect / fit-mode picker** (`VideoFitMode` in `exo_player.dart`): the bottom bar's `tune` button opens an "Aspect ratio" sheet with five modes — Fit, Crop to screen, Stretch to screen, 16:9, 4:3 — scrollable and height-capped so it can't overflow in landscape. Choice applies to the native surface (`setResizeMode`) and persists via `FitModeStore` (`dreamplayer.fitMode`), re-applied on every open. Android: `applyFitMode` maps to Media3 `AspectRatioFrameLayout` — Crop to screen = `RESIZE_MODE_ZOOM`, Stretch to screen = `RESIZE_MODE_FILL`, fixed ratios (16:9 / 4:3) = a forced aspect box + zoom-crop (`ForcedAspectPlayerView.forcedAspect`). iOS: `AvPlayerView.setResizeMode` maps to the `AVPlayerLayer.videoGravity` found in the AetherPlayerView hierarchy (fit=`resizeAspect`, crop + fixed ratios=`resizeAspectFill`, stretch=`resize`); fixed ratios are approximations — exact boxes need the engine's own layout hooks, revisit on-device on the iPad.
- **Audio track selection** (mute button replaced): the bottom bar's first button opens an "Audio tracks" bottom sheet listing every audio track from the native Media3 `currentTracks` (language · codec · channels · bitrate), with the active track check-marked. Picking a track calls `setAudioTrack` → native `TrackSelectionParameters` override → `onTracksChanged` re-emits → the top-bar audio chip (live codec + channel count) updates automatically. Native plumbing in `android/.../ExoPlayerView.kt` (`buildAudioTracks`, `selectAudioTrack`), pushed on every event as `audioTracks`/`selectedAudioTrack`; Dart model `ExoAudioTrack` in `lib/services/exo_player.dart`. Verified on-device: Sonic (DTS-HD MA + FLAC) switches DTS-HD → FLAC and the chip follows.
  - **Full track names**: the sheet prefers the container-provided track `label` (e.g. `DTS-HD MA 5.1`, `Commentary`) and appends the channel count unless the name already carries it; otherwise it composes `languageName(lang) · codec · channels`. `ExoAudioTrack` gained a `label` field; ISO-639 codes map to full English names via `languageName()` in `codec_info.dart`.
- **FLAC via FFmpeg + E-AC3 decoder workaround**: a custom `MediaCodecSelector` in `ExoPlayerView.kt` does two things: (1) returns no decoder for `audio/flac` so FLAC falls through to the bundled FFmpeg renderer — the platform MediaCodec FLAC decoder on some devices (incl. this OnePlus) allocates fixed 32 KiB input buffers and large FLAC frames (24-bit multichannel ~54 KiB) die with `DecoderInputBuffer$InsufficientCapacityException: Buffer too small`; (2) skips any `c2.dolby.eac3.decoder` for `audio/eac3`/`audio/eac3-joc` — on this OnePlus the codec2 resource manager repeatedly releases that hardware decoder as soon as it starts, so Media3's audio renderer spins in an endless re-init loop and **no AudioTrack is ever created (silent playback)**. With the Dolby component excluded, the AOSP software E-AC3 decoder is used and the renderer is stable. Verified on-device: Sonic FLAC plays continuously; an E-AC3 (Dolby Atmos, 5.1) track plays with an active AudioTrack (48 kHz, channelMask `0x3f`, no churn, no errors).
- **NextRenderersFactory killed hardware video decode — root cause of 4K60 lag + washed-out HDR (2026-08, Redmi Note 10)**: the app originally built the player with nextlib's `NextRenderersFactory` (`io.github.anilbeesetti.nextlib:media3ext`, pulled in for its FFmpeg audio). Its `buildVideoRenderers` calls `super` then inserts `FfmpegVideoRenderer` at **index 0** — *before* `MediaCodecVideoRenderer` — and `FfmpegLibrary.supportsFormat` claims `video/hevc`, so **every HEVC file decoded in FFmpeg software**: 4K60 stuttered (Snapdragon 678 cannot software-decode it) and colors were washed out because the FFmpeg GL output carries no HDR dataspace (SF composite: `dataspace 0x0`, `hdr metadata types=0`). Diagnosed by A/B against moneytoo's Just Player (`com.brouken.player`), which uses the **stock** `DefaultRenderersFactory` (`setExtensionRendererMode(mPrefs.decoderPriority)` + `setMapDV7ToHevc`, zero manual HDR code): same file, same `OMX.qcom.video.decoder.hevc`, its layer composited `BT2020_ITU_PQ hdr metadata types=1`. Fix: new `DreamRenderersFactory` (`android/.../DreamRenderersFactory.kt`) — a `DefaultRenderersFactory` subclass that overrides **only** `buildAudioRenderers` to append nextlib's `FfmpegAudioRenderer` **at the end** (audio fallback for DTS/TrueHD/FLAC; stock reflection for `androidx.media3.decoder.ffmpeg.*` finds nothing in the APK, so no video extensions load). Video stays on stock `MediaCodecVideoRenderer`. Verified on Redmi: Sony 4K60 → `[OMX.qcom.video.decoder.hevc] setting surface generation` (hardware session), SF layer `dataspace=BT2020_ITU_PQ hdr metadata types=1` — byte-for-byte the Just Player profile. Note: on API 26–32 the `TIRAMISU` gate keeps `applyHdrHeadroom` off, so SF auto-tone-maps HDR→SDR (correct for a 500-nit HDR10 panel).
- **Subtitles — embedded + sideloaded with a full track picker**:
  - **Sibling auto-pairing** (`android/.../SubtitleFormats.kt` `findSiblingSubtitles`): on open, scans the video's folder and attaches **every** subtitle file as a Media3 `SubtitleConfiguration` (exact-filename-prefix match wins; ordered best-match first). The best match carries `SELECTION_FLAG_DEFAULT` so it's auto-selected; all others remain selectable in the picker. An explicitly passed `subtitleUri` still wins over pairing.
  - **`open()` path fix**: `lib/services/exo_player.dart` `open()` now sends `path` even when a `uri` is present — intent-opened files were dropping the path, so sibling pairing never fired. Verified on-device.
  - **Formats**: SRT, SSA/ASS, WebVTT, TTML/DFXP, SAMI (`.smi`), MicroDVD (`.sub`), MPL2 (`.mpl2`), SubViewer (auto-detected inside `.sub`). `SubtitleFormats` maps extension → MIME (incl. custom `application/x-sami`, `application/x-microdvd`, `application/x-mpl2`).
  - **Custom parsers** (`android/.../DreamSubtitleParserFactory.kt`): Media3's stock `DefaultSubtitleParserFactory` lacks SAMI/MicroDVD/MPL2/SubViewer, so `DreamSubtitleParserFactory` adds `SamiParser` and `FrameSubParser` (MicroDVD/MPL2/SubViewer modes) and delegates everything else (SubRip, SSA, WebVTT, TTML, PGS, VobSub, DVB, TX3G, CEA) to the default. Wired into both `DefaultMediaSourceFactory` and `DefaultExtractorsFactory` so the `SubtitleExtractor` picks it up.
  - **Charset handling**: Media3's text parsers decode UTF-8 only; `SubtitleFormats.toUtf8` detects BOM/strict-UTF-8 vs CP1252 and re-encodes non-UTF-8 sidecars to a cache file so legacy `.srt` files don't render as mojibake. `decodeToString` strips UTF-8 BOM for the custom parsers.
  - **Subtitle picker** (`lib/screens/player_screen.dart`): the bottom bar's CC button opens a sheet listing every subtitle track from native `currentTracks` (embedded container tracks + sideloaded files) plus Off. Labels append the format so sibling files read uniquely (`House.S02E04.eng · SRT`, `House.S02E04 · WebVTT`). Picking a track calls `selectSubtitleTrack` → native `TrackSelectionParameters` override; `selectedSubtitleTrack` re-emits → the CC button reflects the real selection.
  - **Note**: sibling auto-pairing needs `MANAGE_EXTERNAL_STORAGE` — without it, `listFiles()` only sees MediaStore-indexed files (SRT/TTML/SMI) and `.ass`/`.vtt`/`.sub`/`.mpl2` are silently skipped. Every `flutter install` re-revokes All Files Access on Android; re-grant via `adb shell am start -a android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION` (can't be granted via `adb shell pm grant` — this device blocks it).
  - Verified on-device (`House.S02E04` MKV + 7 sidecar formats): embedded PGS + all 7 sidecars attach, best-match `.eng.srt` auto-selected.
- **File browser (CX-Explorer style)** (`lib/screens/file_browser_screen.dart`): browse storage in-app and play any video without importing. **Back goes up one folder at a time** — only a folder whose path IS a root returns to the roots list; any other folder loads its parent (even when the parent is itself a root), so back from a folder inside a root lands on that root's contents, not on "Browse files". Reached from the home **+** button → "Internal storage" (the root list no longer shows a "Pick a folder" tile — adding folders lives on the home **+** menu's "Add folder to library"). Android side (`android/.../FileBrowser.kt`, channel `dreamplayer/files`): `hasAllFilesAccess` / `openAllFilesAccessSettings` / `getStorageRoots` (internal + SD card) / `listDirectory` (folders then video files, sorted, with sizes) / `pickFolder` (launches `ACTION_OPEN_DOCUMENT_TREE`, persistable URI grants stored in SharedPreferences as `dreamplayer.folderBookmarks`, result delivered via `MainActivity.onActivityResult` → `FileBrowser.onFolderPicked`) / `pickLibraryFolder` (same picker, but stores the tree under a library-only `libfolder.<uuid>` key so it never becomes a file-browser root) / `removeBookmark` / `removeLibraryBookmark`. Bookmarked trees are appended to `getStorageRoots` with a `bookmarkId` and are listed through `DocumentFile` via synthetic paths `tree:<id>` / `tree:<id>/<relative>` (directory entries keep the synthetic path for back-navigation; video entries carry their `content://` document URI so `file_browser_screen.dart` passes it as `VideoItem.uri`, like the "Open with" flow). Requires **`MANAGE_EXTERNAL_STORAGE`** (All Files Access) on Android 11+ — the screen shows a "Grant access" button that opens the system settings and re-checks on app resume (the folder picker works without it, but browsing does not). iOS side (`ios/Runner/FileBrowser.swift`): sandboxed, so the root list is a virtual **"Files"** entry (`isFilesHome: true`, synthetic path `dreamplayer/files-home`) that opens the **system document picker** — the real Files-app home (iCloud Drive, On My iPad, Downloads, other providers); picking a video imports it (`importFile` → bookmark stored in `dreamplayer.importedVideos`, re-granted later via `resolveImportedPath`) and plays it. Below it: the app's Documents folder plus **bookmarked folders picked via the system document picker** (`pickFolder` → `UIDocumentPickerViewController` for `.folder`, `removeBookmark`) — security-scoped bookmarks stored in UserDefaults keep picked folders (iCloud Drive, On My iPad, other providers) readable across launches, so videos outside the sandbox are browsed/played in-app without touching the Files app. The Dart screen shows a "Pick a folder" tile + per-bookmark remove at the root on **both** platforms (subtitle text is platform-specific). Tapping a video builds a `VideoItem` and pushes `PlayerScreen`. Verified on-device (Android): Internal storage → Download → video → Dolby Vision People plays with live HDR/codec chips.
- **"Open with" / file-explorer integration** (`AndroidManifest.xml` `ACTION_VIEW` intent-filters for `content`/`file` schemes + video MIME types incl. `video/*`, matroska, mpeg, ts, avi, wmv, octet-stream): tapping a video anywhere on the device now offers DreamPlayer. `MainActivity` resolves the intent (file path or `content://` URI + display name via `OpenableColumns`) and forwards it over the `dreamplayer/intent` channel (`getInitialIntent` on launch / `open` on `onNewIntent`); `lib/services/open_intent.dart` turns it into a `VideoItem` and pushes `PlayerScreen` via a global `appNavigatorKey` in `lib/app.dart`. `VideoItem` gained an optional `uri` (content URIs) with `path` now nullable; `ExoPlayerView` opens a raw URI when no path is available. Verified on-device: "Open with" chooser lists DreamPlayer and launches Dolby Vision playback.
  - **CX Explorer network-stream handoff**: CX hands SMB videos to players as `http://127.0.0.1:<port>/SMB/...` (its own local HTTP proxy), so the intent filter additionally declares `http`/`https`/empty schemes (`<data android:scheme=""/>`) + the full container-MIME matrix (`video/x-matroska`, `application/octet-stream`, `application/mpeg`, ... — a single filter, since per-vendor MIMEs differ), and `android:usesCleartextTraffic="true"`. Media3's `DefaultDataSource` handles file/content/asset itself and sends every other scheme (http/https) to the base factory, so `ExoPlayerView.kt` wires `DefaultHttpDataSource.Factory()` as that base — CX's proxy streams arrive there with no fallback and no extra code. Verified on-device via logcat: 4K HEVC lossless (3840×2176@60) streamed through CX's proxy decoded at a steady 60 fps / **0 discarded frames** for a full session (`c2.qti.hevc.decoder` telemetry), only jank = the app's cold start.
- **Home/settings status bar**: `RootShell` maps `MediaQuery.viewPadding.top` into `padding` (Android edge-to-edge reports `padding.top == 0`), so `SliverAppBar` never overlaps the status bar.
- **User-added folder library** (`lib/services/library_folders.dart`, `lib/widgets/folder_card.dart`, `lib/screens/folder_screen.dart`): the home "Your library" section lists **only folders the user explicitly adds** (home **+** → "Add folder to library") — nothing is auto-scanned. Adding a TV-show folder kicks off a TMDB lookup (`TmdService.resolveFolder`, TV-biased via `TmdApi.bestForQuery`); the card shows the show's poster + real title + TV/Movie badge. Tapping a folder opens its contents (subfolders navigable; episodes listed with parsed `SxxExx` + size), and tapping an episode goes to `TmdDetailsScreen` → player. Long-press a folder card to remove it from the library (files untouched).
- **Continue watching** (`lib/services/continue_watching.dart`): the home library grid lists every video with a saved resume position, most recent first, with a progress bar + "Continue from m:ss" subtitle. `ResumeStore` keeps the playhead (position bookmarked every ~5 s, on pause/background/dispose, cleared at the end); `ContinueWatchingStore` (shared_preferences JSON key `dreamplayer.continueWatching`) mirrors it into lightweight `VideoItem` JSON (id/title/path/uri/resumeKey/duration/sizeBytes) for positions ≥ 10 s. Long-press a card to drop it from it. **Source badge**: each card shows a bottom-left badge naming where the video plays from — `VideoItem.playbackSource` (enum `PlaybackSource` in `video_item.dart`) maps the `resumeKey`/`uri`/`path` to WebDAV (`webdav_` key), CX SMB (`cx:`), Files / SMB (`folderbookmark:` iOS pick-a-folder), legacy SMB (`smb:`), Files (`content://`, `file://`, plain path), or Network (other http/https); `video_card.dart` renders it with a per-source color. **No thumbnails**: cards show the gradient/play-icon placeholder only (the frame-extraction machinery — `getVideoThumbnail`/`MediaMetadataRetriever`/`AVAssetImageGenerator` and the http prefix-download path — was fully removed, so this is now the permanent card look, not a fallback). The player `open()` re-grants the iOS security-scoped bookmark before playback.
- **Responsive grid** (`lib/screens/home_screen.dart`): column count and card height computed from screen width; card text is `Expanded`/`Flexible`. Text scaling clamped to 1.3x app-wide.
- **Native refresh rate** (`lib/services/display_refresh_rate.dart`): calls `FlutterDisplayMode.setHighRefreshRate()` on Android at startup.
- **Resume playback** (`lib/services/resume_store.dart`, shared_preferences): a video stopped mid-way resumes from where it left off on the next open. Position is bookmarked every ~5 s while playing, on pause, on app-background, and on player dispose; cleared when the video plays to the end. `ExoPlayerController.open` gained `startPositionMs` (native: iOS passes it as `startPosition` to `engine.load`, Android seeks before `play()`). Resume keys are the file path / content URI by default; sources whose playable URL rotates between sessions (iPad SMB token URLs) pass a stable `VideoItem.resumeKey` (`smb:<serverId>/<share>/<path>`). Skips trivial positions (<10 s) and "basically finished" ones (within 5 s of a known duration).
  - **Lock/unlock survival (2026-08)**: Android destroys the video surface on lock and may recreate the whole platform view on unlock, leaving a fresh ExoPlayer reset to IDLE while the UI still shows the old playing state. The player screen pauses on background (saving the position) and, on resume, queries the native player's live state via a new **`getState`** channel method (`dreamplayer/exo_<id>`): if the media was lost (IDLE) it reopens at the saved resume position, otherwise it just continues playing. `getState` is implemented on both Android (`ExoPlayerView.kt`, `state`/`positionMs`/`durationMs`) and iOS (`AvPlayerView.swift`) behind the shared controller contract. Related fix: a launcher tap after unlock (singleTop `MainActivity` MAIN intent via `onNewIntent`) must not push an empty player — non-VIDEO intents return null and are ignored in Dart (`open_intent.dart`) and skipped natively.
  - **Stable resume keys for network/file-provider sources (2026-08)**:
    - **iOS bookmarked folders** (FileBrowser.swift): every video listed under a bookmarked-folder root (iCloud Drive / On My iPad / SMB via Files "Connect to Server") carries `resumeKey: folderbookmark:<bookmarkId>:<path-relative-to-CURRENT-mount>`. The relative part is computed against the re-resolved bookmark root each listing, so the key survives the provider remounting the share at a different path between launches. Continue-watching card taps re-grant the folder's security-scoped access via a new `resolvePath` channel method (`dreamplayer/files`) — it falls back to the per-file imported map, then matches any folder bookmark whose resolved URL is a path prefix of the file. (`resolveImportedPath` alone never matched folder bookmarks, so a card tap after relaunch could fail with a permission error.) Android's `resolvePath` is a no-op `true`.
    - **Android CX Explorer SMB proxy** (open_intent.dart `_stableResumeKey`): CX hands SMB videos to "Open with" as `http://127.0.0.1:<port>/SMB/<server>/<share>/<file>`; the port rotates every CX session, so `OpenIntent.toVideoItem()` keys on the stable path portion only (`resumeKey: cx:<path>`). Reopening the same file via CX after the port changed resumes from the saved position. The card's stored `uri` still holds the session's URL, so tapping it replays only while CX's proxy port is still alive (post-CX-restart it shows the playback error — re-open via CX to continue).
- **In-app SMB / LAN playback: iOS removed (2026-08); Android SMB stays**. The Android in-app SMB server browser (`smb_screen.dart`, `smb_client.dart`, `SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, jcifs-ng) remains — NAS playback on Android uses the in-app SMB browser, CX Explorer "Open with", WebDAV, and Jellyfin. The iPad flash SMB browser + playback (`SMBClient.swift`, the `smb_screen.dart`/`smb_client.dart` Dart layer, and every `AvPlayerView` SMB path) was deleted — it was **slow** and **didn't play every video**, and audio-track switching could crash the app. The **Network shares** home-screen entry shows **only on Android**; iOS entry is gone. `BufferedSMBReader.swift` STAYS (WebDAV playback still wraps it for read-ahead) and the `AetherEngineSMB` SPM product STAYS (WebDAV's `ByteRangeSource`/`WebDAVByteRangeSource` live in that module). SMB learnings are preserved in the roadmap section below for future development. **Lesson learned on-device**: jcifs-ng's streaming read size is bound by three interlocking properties (`snd_buf_size`/`rcv_buf_size`/`transaction_buf_size`, defaults 65535); raising only the first two did nothing (still ~64 KB reads / ~5 MB/s with constant ring-buffer stalls), and raising `transaction_buf_size` to 8 MiB made the NAS reject reads with `STATUS_INVALID_PARAMETER` ("The parameter is incorrect"); 1 MiB was still rejected. Do not raise buffers past what the NAS's negotiated `MaxReadSize` accepts.
- **WebDAV browsing + playback (Android + iOS)** (`lib/screens/webdav_screen.dart`, `lib/services/webdav_client.dart`, `android/.../WebDAVClient.kt`, `ios/Runner/WebDAVClient.swift`, channel `dreamplayer/webdav`): CX-Explorer-style server list → folders → videos → play. Add/edit/delete servers with an inline connection test; browsing streams video straight to the existing ExoPlayer/Media3 pipeline (Android) or AetherEngine (iOS). Reached from the home **+** button → "WebDAV".
  - **Per-server self-signed HTTPS** (`ExoPlayerView.kt`): the default OkHttp `HttpDataSource.Factory` is replaced with a custom one holding TWO OkHttp clients — a standard client and a permissive one (trust-all `X509TrustManager`/`SSLContext`). A `setPermissive(bool)` flag per open picks the client; `allowSelfSigned` is an **opt-in toggle, default off**, set end-to-end from the save dialog → `WebDavServer` model → `VideoItem` → `ExoPlayerController.open` → native `open`. Only the flagged server gets the permissive client — never globally.
  - **Credentials never cross to Dart**: the password lives only in native prefs; Dart sees a `hasPassword` boolean. The `Authorization` header is built natively on demand (`WebDAVClient.authorizationHeader`, `Basic` base64). No `Log`/`println`/`debugPrint` of URLs, headers, or passwords anywhere.
  - **Encrypted storage** (`androidx.security:security-crypto:1.1.0-alpha06`): passwords in `EncryptedSharedPreferences` (`dreamplayer.webdavSecrets`, AES-256-GCM with Keystore master key), server metadata in `dreamplayer.webdavServers`; one-time migration from the old plaintext prefs then delete. Both pref files are excluded from Android backup via `res/xml/backup_rules.xml` + `data_extraction_rules.xml` (wired in the manifest) — important for a public release.
  - **Friendly errors** (`WebDAVClient.friendlyError`): maps `SSLException`/`UnknownHostException`/`ConnectException`/`SocketTimeoutException` to plain-language messages ("Certificate not trusted — enable 'Allow self-signed'", "Server not found", "Can't connect", "Timed out"), shown inline in the dialog pinned below the fields (outside the scroll view).
  - **URL handling**: `testConnection`/`listDirectory` always probe slash-terminated URLs so the redirect-mangled root (`/dav` vs `/dav/`) doesn't 404; HTTP sends an in-dialog plaintext warning when credentials are set. **Filename decoding gotcha (2026-08)**: hrefs are decoded with `android.net.Uri.decode` (NOT `URLDecoder.decode`, which turns a literal `+` into a space and would mangle names like `224kbps + English` into a 404); Dart `_encodePath` re-encodes each path segment (`+`→`%2B`, `[`/`]`→`%5B`/`%5D`) for playback URLs, and the continue-watching rebuild re-encodes the same way.
  - **Dialog UX** (`webdav_screen.dart`): protocol radio (HTTP/HTTPS, port defaults 8080/8443 filled only when the field is empty or holds a stale toggle default — a typed port is never overwritten), Host/Port/Path/Name/Username/Password fields all use placeholders (`192.168.1.16`, `8080`, `/dav`, `admin`, ...), HTTPS-only "Allow self-signed" switch, port 1–65535 validation, result/error text foreground color.
  - **iOS/iPad** (`ios/Runner/WebDAVClient.swift`, registered in `AppDelegate`): same `dreamplayer/webdav` contract as the Android client, with **Keychain** passwords (`com.dreamplayer.app.webdav`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; server metadata in UserDefaults) and a two-session `URLSession` setup — standard trust + `PermissiveTrustDelegate` (opt-in per server, mirroring Android's `setPermissive`). Browsing is `PROPFIND` (`Depth: 1`) parsed by a `MultistatusParser`; `testConnection` probes slash-terminated URLs and falls back to a GET probe on 404, and `friendlyError` maps SSL/DNS/connect/timeout `URLError`s to the same plain-language messages. **XML namespace gotcha (2026-08)**: Apache/nginx/Nextcloud/Synology all emit prefixed multistatus XML (`<D:response xmlns:D="DAV:">`); with `shouldProcessNamespaces` left at its default `false`, Foundation's `XMLParser` reports `elementName` as `"D:response"` (prefix included) so the local-name matches in `MultistatusParser` never fire and the folder list silently comes back empty ("Nothing here", no error). `parseMultistatus` must set `parser.shouldProcessNamespaces = true` before `parse()` (and now surfaces `parser.parse()` failures as a real error instead of a silent `[]`). Android is unaffected (XmlPullParser reports local names).
  - **iOS playback**: AetherEngine's own HTTP stack can't carry auth headers nor bypass TLS validation, so `AvPlayerView.open` routes any http/https URI that has `headers` or `allowSelfSigned` to `WebDAVClient.makeByteRangeSource` — a `WebDAVByteRangeSource` (`ByteRangeSource`, so it lives in the `AetherEngineSMB` module) that serves every engine read as an independent HTTP `Range` request with the `Authorization` header, on the permissive or default-trust session. It's wrapped in the same `BufferedSMBReader` read-ahead used for SMB (32 MiB window, background prefetch) so the loopback producer never starves on per-read round-trips; the source is stateless per read, so the engine's internal reload on audio-track switch is safe (no SMB-style reopen needed). The blocking size probe (Range: bytes=0-0, at open) is dispatched on a `Task.detached` so the main thread never blocks — `source` is built inside the async load task and `lastSource` is set there so replay/scrub-after-end works.
  - **Local test servers** (user's PC, `192.168.1.16`): Docker `webdav` (bytemark/webdav, HTTP `:8080`, `LOCATION=/dav`, user/pass `dream`/`dream`) + `webdav-nginx` (nginx, HTTPS `:8443`, self-signed certs + proxy config in `/tmp/opencode/webdav-ssl`, `proxy_pass http://172.17.0.2:80` — the webdav container's bridge IP; the host-gateway path `172.17.0.1:8080` is NOT reachable from inside containers on this host). App-normalized URLs make the HTTPS root work as `https://192.168.1.16:8443/dav` (no trailing slash needed).
- **Jellyfin / Emby browsing + playback (Android + iOS)** (`lib/screens/jellyfin_screen.dart`, `lib/services/jellyfin_client.dart`, pure Dart — no native code): home **+** menu → "Jellyfin" → saved servers + **mDNS auto-discovery** → sign in → libraries → folders → play. Direct-play streams the Jellyfin URL with the token as an `api_key` query param, so playback reuses the existing HTTP data sources with **zero native changes** (Android: `DefaultHttpDataSource`; iOS: AetherEngine's loopback producer; self-signed HTTPS honors the same opt-in permissive path as WebDAV via `allowSelfSigned`).
  - **API surface**: `GET /System/Info/Public` (test connection, no auth), `POST /Users/AuthenticateByName` (`X-Emby-Authorization` header), `GET /Users/{userId}/Views` (libraries), `GET /Users/{userId}/Items?ParentId=…&Fields=MediaSources,Width,Height` (folder contents), direct-play `{url}/Videos/{id}/stream?static=true&mediaSourceId=…&api_key=…` (`/Audio/` for audio items). Uses `dart:io` `HttpClient` with `badCertificateCallback` for self-signed TLS (no `http` package dep).
  - **Persistence**: `JellyfinServer` list in shared_preferences `dreamplayer.jellyfinServers` (server name/url/username/token/userId/allowSelfSigned). Token is a session credential but **not a password** — stored in plain prefs for now (same tier as the resume store); passwords never reach Dart or disk.
  - **mDNS**: `multicast_dns` scanning `_jellyfin._tcp` + `_emby._tcp` (PTR → SRV → A), probing each hit's `/System/Info/Public` for the real name/version (multi-interface `lookup` timeouts; multicast can be flaky on Android Wi-Fi — the **Add server** flow is the reliable fallback and discovery stays best-effort). Permissions: `CHANGE_WIFI_MULTICAST_STATE` (Android manifest), `_jellyfin._tcp`/`_emby._tcp` in `NSBonjourServices` (iOS Info.plist). **Jellyfin 7359 probe is the primary scan (2026-08)**: modern Jellyfin **removed its mDNS/Bonjour responder entirely** (verified against 10.11.11 — the only discovery left is `AutoDiscoveryHost`, a proprietary UDP-7359 broadcast protocol: send `"who is JellyfinServer?"`, server answers unicast JSON `{"Address","Id","Name"}`). `discoverServers()` therefore runs BOTH: (1) the native 7359 broadcast probe — `MulticastLockManager.kt` on Android, `JellyfinDiscovery.swift` on iOS (channel `dreamplayer/multicast`, method `discoverJellyfin`) — and (2) the mDNS scan for legacy Emby servers. **Gotcha (2026-08)**: the Android MethodChannel handler runs on the platform MAIN thread, so the blocking socket probe must run on a `Thread` (result posted back via `Handler(Looper.getMainLooper())`) or every send dies with `NetworkOnMainThreadException` and the scan returns nothing — the app also declares `ACCESS_WIFI_STATE` so `wifiBroadcastAddress()` computes the /24 subnet broadcast target. **Android multicast lock (2026-08)**: pure-Dart `multicast_dns` cannot hold the Wi-Fi `MulticastLock`, so the driver drops multicast frames and scans find nothing. `discoverServers()` acquires/releases the lock via the same native manager (`acquire`/`release`) around the whole scan — on non-Android the channel is absent and the helper no-ops. **Server-side gotcha**: a Linux Jellyfin host behind UFW must allow UDP 7359 (`sudo ufw allow 7359/udp`) or broadcasts are silently dropped before the server sees them (avahi is NOT involved — it was a red herring during debugging; do not stop it for Jellyfin).
  - **Browse**: folders first, then playables, alphabetical; breadcrumb back + server-list button. Tapping a playable opens its TMDB details screen and plays it. 401 during browse → token dropped → sign-in prompt re-authenticates.
  - **Continue watching**: stable resume key `jellyfin:<host>/<itemId>`; `home_screen._restoreJellyfinSource` rebuilds the stream URL from the current saved server + token so session rotation can't break card taps. Cards show a purple **Jellyfin** source badge.
  - **Jellyfin folders in the home library (2026-08)**: the folder tiles in the Jellyfin browser carry an **Add to library** button (`library_add_outlined`, row tap still navigates) that persists a `LibraryFolder` with `source: jellyfin` + the server URL + item id — the token is never stored, the entry is re-matched against the saved servers (`JellyfinClient.serverForUrl`) each time it's opened, so it keeps working across logins. The home "Your library" grid shows these as regular folder cards with a teal **Jellyfin** badge (`folder_card.dart`), and tapping one opens `TmdDetailsScreen(folder:)` in **Jellyfin mode**: `getItems` lists the children via the API (folders then playables, alphabetical), playables show their `IndexNumber`/`ParentIndexNumber` (`Fields=…IndexNumber,ParentIndexNumber`) as `SxxExx` + TMDB episode names when the season data is cached, tapping one carries the show's meta and plays the direct-play URL (`JellyfinClient.videoItem`); subfolders deep-link into `FolderScreen`, which also gained a Jellyfin branch (crumb stack of item ids + names instead of `listDirectory` paths). Removing the folder from the library skips the native `removeLibraryBookmark` (no SAF grant for a Jellyfin folder). `LibraryFolder.fromJson` defaults a missing `source` to `files`, so legacy entries are untouched. **Auto-fetched series info (2026-08)**: bookmarking also fetches the item's own metadata from the server — `JellyfinClient.getItemInfo` builds a `JellyfinItemInfo` (name, year, genres, rating, overview + full poster/backdrop URLs with the token as `api_key` — deliberately NOT folded into `TmdMovie`, whose `posterUrl()` always prefixes `image.tmdb.org`). **Series-poster resolution (2026-08)**: a bookmarked folder is often a plain `Folder`/`Season` with no poster of its own, and Jellyfin answers `/Items/{id}/Images/Primary` for such an item with a **random child image** (a random still from the series) — so `_addToLibrary`, `home_screen._refreshJellyfinMeta` and `TmdDetailsScreen._refreshJellyfinInfo` all call `JellyfinClient.getPrimaryPosterInfo` instead, which keeps the item itself only when it is a `Series`/`Movie` and otherwise walks `getItemAncestors` (`GET /Items/{id}/Ancestors`, a JSON array, hence the `_getJsonRaw` variant of `_getJson`) to the nearest `Series` ancestor and uses that item's Primary poster. Pure decision logic lives in `JellyfinClient.resolvePosterItemId` (unit-tested). and caches it under `dreamplayer.jellyfinFolderMeta` (`saveFolderMeta`/`removeFolderMeta`/`loadAllFolderMeta`). The home card shows the Jellyfin poster + TV/Movie badge as a fallback when no TMDB match exists (`FolderCard.jellyfinInfo`); `TmdDetailsScreen` gained a `jellyfinInfo` param + `_refreshJellyfinInfo` (refreshed on open so the token-embedded artwork stays current, since re-login rotates the token) and `_buildFolderWithoutMatch` renders a full backdrop/poster/rating/genres/overview header for Jellyfin folders. `home_screen._refreshJellyfinMeta` fills cache gaps for folders bookmarked by older builds; `_removeFolder` drops the cached info. Image URLs embed the session token, so they can go stale after re-login — the details-screen refresh covers that (cards fall back to the placeholder on a broken image).
- **TMDB details screen for every source (2026-08)**: tapping a video now opens `TmdDetailsScreen` (metadata page with Resume/Play) instead of jumping straight to the player — from continue-watching cards, and from the WebDAV, Jellyfin, and file browsers. **Library folder taps route to the details screen too (2026-08)**: the home "Your library" grid's `_openFolder` pushes `TmdDetailsScreen(folder: folder)` — the folder's TV metadata (poster, seasons, backdrop) with a Play/Resume button — instead of `FolderScreen`. `_resolveFolderMetadata` now ALSO eagerly calls `TmdService.detailsFor(folder.metadataKey)` right after `resolveFolder` so the details/backdrop are already cached when the folder is tapped (add-time fetch). The details screen's folder mode navigates subfolders via `FolderScreen(folder:…, initialPath: entry.path)` — `FolderScreen` gained an `initialPath` parameter (defaults to `widget.folder.path`) so a subfolder tap deep-links straight into that directory. **JSON dual-key gotcha (2026-08)**: `TmdSeason`/`TmdEpisode` `fromJson` reads both the TMDB API snake_case keys (`season_number`, `episode_number`, `still_path`, `air_date`, `runtime`, `vote_average`) AND the camelCase keys that `toJson` writes (`seasonNumber`, `episodeNumber`, `stillPath`, `airDate`, `runtimeMinutes`, `voteAverage`) — a single-style `fromJson` silently nulls fields when round-tripping through the prefs cache, breaking the episode-name fallback ("Episode N") and season lookups. **Season-folder title parsing (2026-08)**: whole-season folder names like `HOUSE.S02.1080p.10bit.BluRay.English.AAC.5.1.x265-Panda` used to resolve to `"HOUSE S02 English"` — a TMDB query with **0 results**, so the folder card never got its poster and showed the Jellyfin fallback image instead. `ParsedFileName.parse` now (1) strips a **bare season tag** (`\bS(\d{1,2})\b`, matched only after the `SxxEyy`/`NxM` patterns) and records it as `season`, so `HOUSE.S02...` → title `"HOUSE"`; (2) the noise list gained `english`/`eng` (audio-language tags) and `nf`/`netflix`/`amzn`/`amazon`/`hbo`/`hulu` (streaming-provider tags); (3) `_cleanName` explicitly removes `H.265`/`H265`/`H 265`/`X.264`-style codec tags (the dot/space defeats the `\bh265\b` word-boundary noise rule), so `I.Will.Find.You.S01.2160p.NF.WEB-DL...H.265-...` → `"I Will Find You"`. Both regressions are unit-tested in `test/tmdb_test.dart`. **Details-screen header is landscape-aware (2026-08)**: `TmdDetailsScreen._headerBox` keeps the full-width `width * 9/16` banner in portrait but in landscape shows the artwork as a **centered 16:9 box** capped to `(height * 0.32).clamp(140, 240)` — the 16:9 image renders whole (no `cover`-crop) instead of being zoomed into a thin strip or filling the whole landscape viewport. The gallery fills its parent (`SizedBox.expand`) so the call sites own the box; the rating badge is anchored inside the box. `_CastTile` name+character lines live in an `Expanded`+`FittedBox(scaleDown)` so they fit the fixed 96px tile at any text scale (the overflow tests now actually exercise the cast rows in landscape). **Play-next removed (2026-08)**: the player and detail screens no longer chain a sibling playlist — each video plays on its own; the call sites stopped passing folder playlists. The action button reads `ResumeStore.positionFor(resumeKey)` (same key chain + same <10 s / near-end thresholds as the player) and labels itself **"Resume from m:ss"** when a playhead is saved; the player still auto-resumes via its own lookup, so no start position is passed. The player screen re-checks the label after the player pops. **Playback is never blocked by metadata (2026-08)**: the Play/Resume button is pinned in the bottom bar and always enabled — a slow or failed TMDB lookup (timeouts, unreachable `api.themoviedb.org`, invalid/rate-limited key) shows the real `TmdException` message in the "no match" card instead of the old generic "check your connection", and the video still plays.
  - **Scoped out (v1)**: subtitle delivery (server-side subs via direct-play need a separate `SubtitleConfiguration`/track flow), per-item thumbnail art in browse lists (folder/series art IS done via `JellyfinItemInfo`), HLS/transcode selection, per-library refresh. Add-on checklist if in-app SMB ever returns (below) does not apply here — Jellyfin playback is plain HTTP.
- Tests: 131 (`flutter test`) incl. no-overflow checks on small phone, tablet, landscape, 2.0x text scale, and the TMDB-details/Jellyfin server-list overflow regression states, a file-browser back-navigation test (back goes up one folder at a time; a folder inside a root lands on that root's contents, not the roots list), an About → "Open-source licenses" navigation test, Jellyfin model/URL unit tests (incl. `JellyfinItem` IndexNumber/ParentIndexNumber → `SxxExx`, `videoItem` building the playable `VideoItem`, and `JellyfinItemInfo` fromApi URL construction + cache round-trip + folder-meta store), TMDB filename-parser / metadata-store round-trip tests (incl. the 2026-08 search-query regressions: bracket/paren audio-metadata stripping, bitrate + release-group/site suffix cutting, and underscore-glued episode tags), `TmdSeason`/`TmdEpisode` JSON round-trip + "Episode N" fallback + cast/stills round-trip + `withEpisode` tests (the dual-key `fromJson` regression), and library-folder store unit tests (`test/library_folders_test.dart`, incl. the Jellyfin-source round-trip + legacy `source`-less default).
- **Licensing**: the app is **GPLv3** because the Android build links `nextlib-media3ext` (GPLv3 FFmpeg extension). `LICENSE` (GPLv3 text) + `NOTICE` (third-party components: Media3 Apache-2.0, nextlib GPL-3.0, AetherEngine LGPL-3.0 + Apple Store exception, FFmpegBuild LGPL-2.1+, SMBClient MIT — bundled via AetherEngineSMB for WebDAV, Flutter BSD-3-Clause, pub plugins MIT/BSD). The About section of Settings opens `licenses_screen.dart`, which lists every component and its license.
- **TMDB movie metadata** (`lib/services/tmdb_client.dart`, `lib/screens/tmd_details_screen.dart`, `lib/config/tmdb_api_key.dart`, pure Dart — no native code): continue-watching cards resolve their filename against **The Movie Database** for poster/backdrop art, the real title, year, synopsis, rating, genres, runtime, and cast. `TmdApi` keeps **one shared keep-alive `HttpClient`** for the app lifetime (a fresh client per request re-armed DNS+TLS each call → slow + intermittent `SocketException` on flaky links) with 15 s connect / 30 s response timeouts and **one retry** for transient failures (`SocketException`, `TimeoutException`, HTTP 429 rate-limit burst) before surfacing the `TmdException`. The scene-name parser (`ParsedFileName`) strips quality/codec/audio-channel noise (`1080p`, `WEB-DL`, `DDP5.1`, release groups after a dash like `-GROUP`, season/episode tags `S01E03`) while keeping title words like "Part" (`Dune.Part.Two`). **Search-query parser cleanup (2026-08)**: bracketed/parenthesized audio metadata is dropped from the query (`[Hindi AMZN DDP 2.0 224kbps + English DTS-HD MA 5.1]`, `(Hindi DDP 5.1 Korean DTS 5.1)`) unless the group carries an episode tag (`[S02E04]`) or the year (`(2013)`), both of which must survive for detection; bitrate tokens (`224kbps`, `640kbps`) are removed; `<group>-<site>` release suffixes (`USURY-4kHdHub.com`) are cut including the bare group; and underscore/bracket-glued tags (`Stranger_Things_[S02E04]_1080p`) are normalized to spaces so the word-boundary noise rules fire. Verified on-device against real NAS filenames: `Silence`, `Identity`, `Oldboy`, `Her (2013)`, `24`, `Main Vaapas Aaunga` all auto-match at score 1.00 (the old parser searched for garbage like "Silence MA"). Resolution order for the API key: the `--dart-define=TMDB_API_KEY` build-time value (seeded into prefs on first launch so later plain `flutter run`s keep working) → empty. **No key is ever committed**: the repo default is the empty env define; the user's key lives in gitignored `.env` (see `.env.example`) and is baked in via `--dart-define-from-file=.env`. (The Settings → Metadata API-key entry was removed — the key is build-time only.) **UI flow**: tapping a continue-watching card now opens `TmdDetailsScreen` (backdrop header, poster, star rating, runtime + genre chips, overview, cast row, big Play button) instead of the player directly; "Fix match" opens a TMDB search dialog to re-pin the entry (persisted via `TmdStore.setManual`) and "Remove info" clears a wrong auto-fetched match (`TmdService.clear` → cache + prefs dropped, home cards fall back to placeholder). Metadata is cached in shared_preferences (`dreamplayer.tmdbMeta`, keyed by `TmdStore.identityKeyFor` = resumeKey ?? path ?? uri); `home_screen` pre-resolves cards on load and the player shows the movie backdrop behind its loading/error layer. Cards without a match keep the gradient placeholder. Search/details run over `dart:io` HttpClient; no new native code.
- **Per-episode details** (`lib/services/tmdb_client.dart`, `lib/screens/tmd_details_screen.dart`): the single-episode details page shows **that episode's** name, overview, air date, runtime, rating, guest cast, and still frames instead of only the show's metadata. The season endpoint (`/tv/{id}/season/{n}`) supplies the name/overview/still; `TmdApi.episodeDetails` additionally hits the **per-episode endpoint** (`/tv/{id}/season/{n}/episode/{m}` with `append_to_response=credits,images`) for the guest cast + full still gallery. `TmdService.episodeDetailsFor` enriches the cached `TmdEpisode` in place (via `TmdSeason.withEpisode`) and runs only for the single-episode view (video mode), never for whole folder lists — so a folder with 100 files triggers no per-episode requests. `TmdEpisode` gained `cast`/`stills` fields with **dual-key JSON** (API `credits.cast`/`images.stills` vs cached `cast`/`stills`), so the prefs cache round-trips. UI: the header uses the episode still when season data is loaded, and an "Episode cast" row + horizontal **Stills** gallery sit between the episode overview and the show's cast. All best-effort: on API failure the episode silently keeps its season-level data.
- **Donations**: Settings → **Support** lists two donation channels (Razorpay, GitHub Sponsors) via `lib/services/support_links.dart` (`url_launcher`). **Razorpay is set** (`https://rzp.io/rzp/cZ5afqVG`, a live payment link → `plink_TOrUqMDPRxYQFp`) and **GitHub Sponsors is set** (`https://github.com/sponsors/mangeshghodke/`). README has matching badges + a Support section.
- **Settings footer (2026-08)**: Settings → bottom shows "Made with ❤️ by Mangesh Ghodke".

## Roadmap

### SMB / network shares (Android + iPad)

Play files from LAN/NAS SMB shares in-app, mirroring the existing file-browser pattern.

**Status: iOS removed (2026-08); Android SMB stays.** The Android in-app SMB browser (`smb_screen.dart`, `smb_client.dart`, `SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, jcifs-ng) is implemented and running on-device. The iPad in-app SMB browser (AMSMB2 + AetherEngineSMB) shipped but was retired (2026-08): slow, didn't play every video, audio-track-switch crash. iOS `SMBClient.swift` and Dart layers were DELETED; Android `smb_screen.dart`/`smb_client.dart` remain. The "Network shares" home entry shows **only on Android**. WebDAV/Jellyfin/Files-app "Open with" + bookmarked folders cover iOS NAS workflows. The complete SMB knowledge below is the blueprint if iOS SMB ever returns.

**Architecture**
- New native module per platform exposing a MethodChannel (same shape as `FileBrowser.kt` / `dreamplayer/files`):
  - Android: `SMBClient.kt` — channel `dreamplayer/smb`
  - iOS/iPad: **removed** (was `SMBClient.swift` — same channel)
- Dart: `lib/services/smb_client.dart` (models + channel wrapper) + `lib/screens/smb_screen.dart` (server list → shares → folders → tap video → `PlayerScreen`).
- Playback passes an `smb://` URI through the existing `uri` path in `VideoItem` (like the "Open with" flow).

**Libraries**
| Platform | Choice | Why |
|---|---|---|
| Android | **jcifs-ng** (SMB2/3 only) | Nova's and CX File Explorer's SMB library; measured ~75 MB/s vs ~4–6 MB/s for smbj on the NAS. |
| Android (optional) | jcifs-ng SMB1 | SMB1 legacy devices only (disabled by default; SMB1 support is behind a config flag) |
| iPad | **removed (2026-08)** | AMSMB2 / SwiftSMB retired; NAS playback is WebDAV / Jellyfin / Files-app "Open with". `AetherEngineSMB` still ships for WebDAV's `ByteRangeSource`. |
- **Licensing**: libsmb2 is LGPL-2.1 (constrains App Store distribution — needs relinkable/replaceable lib); app already ships GPLv3 FFmpeg extension so not a new concern for Android.

**Features**
1. *Servers*: add/edit/delete saved servers (name, host/IP, port 445, user, password, or Guest); credentials in Keychain (iOS) / Android Keystore (EncryptedSharedPreferences), never plaintext; LAN auto-discovery (broadcast/workgroup) + manual IP fallback; test connection + quick connect; saved-server status dot (online/offline).
2. *Browsing* (CX-Explorer style): server → shares → folders → files; breadcrumbs + up-nav; folders first, sorted by name/size/date; show size + modified date; player back returns to same folder.
3. *Playback*: direct streaming (no download) — Android = custom ExoPlayer `DataSource` over jcifs-ng seekable reads; iPad = `AVAssetResourceLoaderDelegate` serving bytes from the SMB stream; full seek; existing live HDR/codec chips unchanged; play-next-episode in folder; optional prefetch/cache-ahead setting + reconnect-on-drop/resume for high-bitrate files.
4. *Extras*: auto-pair subtitles from same folder (`.srt`/`.ass`); pin recently-used servers on home screen; DNS/WINS hostname resolution for NAS names.
- **Scope (v1)**: manual server add + Guest/basic auth + browse + stream + play-next. Add discovery + subtitles after.
- **Status**: v1 core landed (Android): discovery, status dots, play-next-episode and subtitle auto-pair are implemented and the app is running on-device; the Nova-style read-ahead ring buffer is implemented but **not yet verified against a real NAS**. Remaining: **full NAS verify of streaming/seek + subtitles + play-next** (share browsing is verified), Reconnect-on-drop/resume for high bitrates, and the iPad path (needs an SMB2 client on the Swift side). **TMDB auto-fetch on video tap (2026-08)**: tapping an SMB video opens the details screen already resolved — the browser prefetches metadata under the same stable key the tap uses (`smb_<serverId>/<share><path>`) so the prefetched match is a direct cache hit (before, the two used different keys and the tap re-searched — and a tap during an in-flight prefetch returned a false "no match" via the old `Set`-based deduper; `TmdService` now dedupes with a `Map<String, Future<TmdMeta?>>` so concurrent callers share one in-flight search). Verified on-device: `Silence`, `Identity`, `Oldboy`, `Her (2013)`, `24`, `Main Vaapas Aaunga` all resolved to score-1.00 matches from the SMB folder prefetch.
- **iOS/iPad status — shipped then DELETED (2026-08)**: the in-app SMB browser + playback landed for iPad via **AMSMB2** (`ios/Runner/SMBClient.swift`, channel `dreamplayer/smb`, same Dart `SmbClient` contract as the removed Android one) + **AetherEngineSMB** (the engine's official SMB product — `SMBConnection` + `SMBIOReader`). `openShare` returned a per-file `dreamplayersmb://<token>.<ext>` URL; the platform view resolved the token to the live `SMBConnection` and loaded it as a custom `IOReader` source (`engine.load(source: .custom(SMBIOReader(...), formatHint: nil))` — the demuxer probed the container itself). `closeShare(serverId)` closed every connection for the server. Servers persisted in UserDefaults (passwords in Keychain, never to Dart); shares listed via `listShares` + manual add-share; directory listing sorted folders-then-videos and auto-paired sibling subtitles (`subtitlePath` downloaded to a temp file — subtitles are small — and returned as a `file://` URL for `ExternalSubtitleTrack`). LAN scan (`discoverServers`) probed the local /24 on port 445. Registered in `AppDelegate`; `NSBonjourServices` + `NSLocalNetworkUsageDescription` in Info.plist; AMSMB2 (SPM 4.0.0) + AetherEngineSMB (product of the AetherEngine package, added to the Runner **Embed Frameworks** phase) were in the project. **Why not the loopback HTTP proxy:** AetherEngine's bundled FFmpeg has **no network stack** — it plays remote URLs through its own "loopback producer" with one long-lived connection + open-ended ranges; a hand-rolled HTTP server (`Connection: close`, no keep-alive) mismatched that protocol and "Share connects but video won't open" persisted across ATS / extension+Content-Type / connect-race fixes (v0.0.3). AetherEngineSMB was the engine-native path for NAS/SMB sources. **Why it was retired (2026-08-13):** it was **slow** and **didn't play every video**, and picking a different audio track on an SMB stream could **crash the app** on-device. The EPERM failure was fixed (`reopenSMBStream` + `SMBClient.reconnect` mint a fresh connection) and the buffering spinner got `BufferedSMBReader`, but a hard crash remained in the reopen/teardown path (stale-connection close racing an in-flight read). Since local playback is smooth and NAS files reach the app via CX/Files "Open with", the entry was removed on all platforms with no feature-loss workaround; the code is gone from the tree, kept as the blueprint below. To revive: fix the teardown race, requiring the iPad crash report/console at the moment of the audio-track tap.
  - **Gotcha fixed on-device — dynamic SPM framework not embedded (code deleted, note preserved)**: AMSMB2's package product is `type: .dynamic`, so linking it into Runner is NOT enough. It must ALSO be added to the Runner target's **Embed Frameworks** copy phase (`PBXCopyFilesBuildPhase`, `dstSubfolderSpec = 10`) as a `PBXBuildFile` with `productRef` + `settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy); }`. Without that, `AMSMB2.framework` is missing from `Runner.app/Frameworks/` (the binary still has an `@rpath/AMSMB2.framework/AMSMB2` load command, so the build passes but dyld crashes at launch with "image not found"). Transitive dynamic products (e.g. FFmpegBuild's xcframeworks pulled in by AetherEngine) are auto-embedded; direct package products added by hand to the Frameworks phase are not. **AetherEngineSMB is the opposite — a STATIC library product (its `Package.swift` `products` entry has no `type:`, so the default static applies; same for its `SMBClient` dependency). It must be in the Frameworks (link) phase + `packageProductDependencies`, and must NOT be added to the Embed Frameworks copy phase — with no `.framework` file to embed, xcodebuild fails with `The file "AetherEngineSMB" couldn't be opened because there is no such file`.** (Note: AMSMB2 is gone from the project; AetherEngineSMB STAYS — WebDAV playback's `ByteRangeSource`/`WebDAVByteRangeSource` live in that module.)
  - **"Share connects but video won't open" fix (2026-08-12, superseded)**: the v0.0.3 loopback-HTTP fixes — (1) ATS (`NSAllowsLocalNetworking` for the `http://127.0.0.1` stream URL, since the native AVPlayer path honors ATS), (2) extension + `Content-Type` on the token URL, (3) synchronous connect before returning the URL — did NOT fix playback on-device; the loopback server was retired in v0.0.4 in favor of AetherEngineSMB (see above). The ATS entry stays in Info.plist (harmless).
  - **Gotcha fixed on-device — dynamic SPM framework not embedded**: AMSMB2's package product is `type: .dynamic`, so linking it into Runner is NOT enough. It must ALSO be added to the Runner target's **Embed Frameworks** copy phase (`PBXCopyFilesBuildPhase`, `dstSubfolderSpec = 10`) as a `PBXBuildFile` with `productRef` + `settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy); }`. Without that, `AMSMB2.framework` is missing from `Runner.app/Frameworks/` (the binary still has an `@rpath/AMSMB2.framework/AMSMB2` load command, so the build passes but dyld crashes at launch with "image not found"). Transitive dynamic products (e.g. FFmpegBuild's xcframeworks pulled in by AetherEngine) are auto-embedded; direct package products added by hand to the Frameworks phase are not. **AetherEngineSMB is the opposite — a STATIC library product (its `Package.swift` `products` entry has no `type:`, so the default static applies; same for its `SMBClient` dependency). It must be in the Frameworks (link) phase + `packageProductDependencies`, and must NOT be added to the Embed Frameworks copy phase — with no `.framework` file to embed, xcodebuild fails with `The file "AetherEngineSMB" couldn't be opened because there is no such file`.**
  - **"Share connects but video won't open" fix (2026-08-12, superseded)**: the v0.0.3 loopback-HTTP fixes — (1) ATS (`NSAllowsLocalNetworking` for the `http://127.0.0.1` stream URL, since the native AVPlayer path honors ATS), (2) extension + `Content-Type` on the token URL, (3) synchronous connect before returning the URL — did NOT fix playback on-device; the loopback server was retired in v0.0.4 in favor of AetherEngineSMB (see above). The ATS entry stays in Info.plist (harmless).

### Apple TV (tvOS)

Run DreamPlayer on Apple TV as a real 10-foot app. **Status: NOT STARTED — planned (2026-08).** Do NOT implement until asked; this is the design/blueprint.

**Why it's mostly free already**
- Dart's `Platform.isIOS` returns **true on tvOS**, so the existing platform gates already pick the right path: `ExoPlayerView` (`lib/services/exo_player.dart:407`) builds the **`UiKitView` AetherEngine view**, `player_screen.dart:105` does not block it, and `settings_screen.dart`'s Engine label shows "AetherEngine (AVPlayer + FFmpeg)". Flutter 3.29+ has stable tvOS support (current: 3.44.x).
- **Jellyfin is pure Dart** — server list, 7359/mDNS discovery (mDNS via `multicast_dns` works on tvOS; the native 7359-probe/multicast-lock paths are Android/`defaultTargetPlatform==android|iOS` gated and just won't run — fall back to Add-server, acceptable), browse, direct-play (plain HTTP) all work with **zero tvOS native code**.
- WebDAV playback on iOS routes http(s) URIs with auth/self-signed through `WebDAVByteRangeSource` — that path is portable (AVPlayer-side).

**Work items (in order)**
1. **Scaffold**: `flutter create --platforms=tvos .` → `tvos/` Runner (bundle id `com.dreamplayer.app`, `TVOS_DEPLOYMENT_TARGET = 18.0` to match the iOS `IPHONEOS_DEPLOYMENT_TARGET`; layered tvOS App Icon comes with the template).
2. **Port the native channel/playback stack into `tvos/Runner`** (copy the Swift files + wire `tvos/Runner/AppDelegate.swift` exactly like `ios/Runner/AppDelegate.swift`):
   - `AvPlayerView.swift` (AetherEngine platform view `dreamplayer/exo_player` — the core; includes `BufferedSMBReader`, subtitle overlay)
   - `WebDAVClient.swift` (channel `dreamplayer/webdav` — same contract as Android)
   - `JellyfinDiscovery.swift` (channel `dreamplayer/multicast` — 7359 probe)
   - `FileBrowser.swift` — **Documents-folder only** on tvOS: there is **no Files app / document picker / "Open with"** on tvOS, so `isFilesHome` + folder bookmarks are N/A; keep `resolveImportedPath` for the Documents dir.
   - **Skip `IntentBridge.swift` for v1** (no Files "Open with" on tvOS). In-app SMB was removed on both platforms (2026-08), so there's no `SMBClient.swift` to port; keep `BufferedSMBReader.swift` (WebDAV playback depends on it).
   - Note: `ExoPlayerView` calls `UiKitView` on `Platform.isIOS` — tvOS UiKitView platform views are supported in current Flutter; **verify** the AetherEngine player view mounts in a tvOS-hosted Flutter view (the hybrid view hierarchy differs from iPad).
3. **AetherEngine SPM in the tvOS project** — same wiring as iOS (`ios/Runner.xcodeproj`, SPM URL `https://github.com/superuser404notfound/AetherEngine`, pinned `upToNextMajorVersion` from 6.21.0): add the package + `AetherEngine` product to `packageProductDependencies` + Frameworks phase. **Gotcha to repeat**: AetherEngineSMB/AMSMB2 are iOS-only products — do NOT add them to the tvOS target (AMSMB2 is gone from iOS anyway; WebDAV's `ByteRangeSource` lives in `AetherEngineSMB`, which is a product of the AetherEngine package). **Unknown blocker to verify first**: does AetherEngine's `Package.swift` even declare tvOS? If its platform list is iOS-only, the package needs a tvOS target (upstream change or a local fork) — check before writing any code. FFmpegBuild's xcframeworks must also have tvOS slices (verify the engine's FFmpeg supports `appletvos`).
4. **10-foot UI**: the existing Material UI runs but is touch-centric. Flutter tvOS maps the Siri Remote to focus traversal (Material buttons/ListTiles are focusable), but the app needs a pass: `Focus`-friendly navigation, D-pad/click-driven back, larger touch targets, skip the screen gestures / pinch stuff. Consider the `flutter_tv` / `focus_utils` approach on the home + player controls.
5. **CI**: add a **tvOS build job to `.github/workflows/ios.yml`** (user has no Mac): `xcodebuild -sdk appletvos` on `macos-latest`, unsigned `Runner.app` (+ `ditto` a `DreamPlayer-tvOS.ipa`) artifact, matching the iOS job's manual `workflow_dispatch` trigger. Keep the App Icon + `CFBundleDisplayName`.
6. **Distribution**: no Mac/Apple TV in the user's setup yet — sideload via Xcode (ad-hoc) or a free/personal-team profile once they have a Mac. Same caveats as the iOS IPA (unsigned artifact).

**Out of scope for v1**: SMB browser on tvOS, AirPlay-cast-to-TV from the phone app, HDR/DV verification on tvOS panels (AVPlayer on tvOS is HDR-capable; re-verify the chips/probe later).

### Library (user-added folders)

The home library shows **only folders the user explicitly adds** — nothing is auto-scanned. **Status: implemented (2026-08; on-device verify pending).** Reference-only: videos are never imported or moved; they stay in place and play through the folder's SAF tree (`tree:<id>`), absolute path, or (for Jellyfin folders) the server API.

**Behavior**
- **Add a folder** — home **+** → "Add folder to library" → system folder picker (`pickLibraryFolder`, `ACTION_OPEN_DOCUMENT_TREE`). The picked folder is saved in `LibraryFoldersStore` (shared_preferences `dreamplayer.libraryFolders`, most-recently-added first; `LibraryFolder` model in `lib/services/library_folders.dart`). **Library folders are bookmark-separated** (2026-08): the pick goes through `pickLibraryFolder` → native stores the tree under a library-only bookmark key (Android `libfolder.<uuid>` in `dreamplayer.folderBookmarks`; iOS `dreamplayer.libraryFolderBookmarks` in UserDefaults), so a library folder is listable by `listDirectory`/`resolveAllBookmarks` but **never appears as an Internal-storage file-browser root**. A TV-show folder (or a movie folder, SD card, USB drive, cloud apps) is the typical target. **Jellyfin folders** are added straight from the Jellyfin browser's folder tiles (see the Jellyfin bullet above) — `LibraryFolder.source` (`LibraryFolderSource.files|jellyfin`) selects the listing backend at open time; a Jellyfin entry stores only the server URL + item id (token never persisted) and is re-matched to the signed-in server on every open.
- **TMDB poster** — on home load (and after adding), `TmdService.resolveFolder(folder.metadataKey, folder.name)` runs in the background; `TmdApi.bestForQuery` searches **TV then movie** (TV hits get a +0.001 tie-boost — folders are primarily shows) and caches the match under `folder:<id>` in TmdStore. `FolderCard` (`lib/widgets/folder_card.dart`) shows the poster + real title + year + "TV Series"/"Movie" badge (plus a teal **Jellyfin** badge for server folders), or a gradient + folder icon while unresolved.
- **Folder contents / episode list** — a home folder card tap goes to `TmdDetailsScreen(folder:)` (details page with Play/Resume); its **"Browse folders"** action (and subfolder deep links) open `FolderScreen` (`lib/screens/folder_screen.dart`, now with an `initialPath` parameter so it can land directly inside a nested folder), which lists the folder via `listDirectory` (`tree:<id>/<relative>` synthetic paths for bookmarks, `content://` URIs for files, subfolders navigable). A TV folder therefore shows an episode list with parsed `SxxExx` labels + file sizes. Tap an episode → `TmdDetailsScreen` → player. **Jellyfin folders** list through `JellyfinClient.getItems` instead (folders → playables, alphabetical, `SxxExx` from the server's `IndexNumber`/`ParentIndexNumber`, TMDB episode names when the season data is cached); subfolders descend through `FolderScreen`'s Jellyfin branch (item-id crumbs), and playables play the direct-play URL built by `JellyfinClient.videoItem`.
- **Remove from library = unlist, never delete** — long-press a folder card → "Remove from library" → the folder is dropped from the store, its native library bookmark is released (`removeLibraryBookmark`, skipped for Jellyfin folders — no SAF grant), and its `folder:<id>` TMDB metadata is cleared (a re-add re-matches cleanly). Files on disk are never touched.
- **Cross-platform**: works on Android (SAF bookmarks) and iOS (Files-app picked folders) — unlike the old MediaStore scan, which was Android-only.
- **Superseded (2026-08)**: the Android-only MediaStore scan (scan-and-show every device video, `READ_MEDIA_VIDEO` grant card, exclusion list) was fully **removed** — `lib/services/library_scan.dart` (`LibraryVideo`/`LibraryScanService`/`LibraryStore`), `test/library_scan_test.dart`, and the native `scanLibrary`/`folderFor` + ContentUris/Cursor/MediaStore imports in `FileBrowser.kt` are gone. The prefs keys it used (`dreamplayer.libraryCache`, `dreamplayer.libraryExcluded`) are dead.
- The iPad equivalent (Photos import) is out of scope — Files/WebDAV/Jellyfin already cover iPad local + network playback.

## CI / Deployment

- **iOS builds happen in GitHub Actions** (user has no Mac). Workflow: `.github/workflows/ios.yml`
  - **Manual-only** (`workflow_dispatch` — no push trigger): run it from the Actions tab when a build is wanted; builds unsigned IPA artifact always.
  - Signed build + TestFlight upload run only when secrets are configured.
  - Secrets needed: `IOS_CERT_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `APPSTORE_API_KEY`, `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID`.
- **GitHub Releases** (`.github/workflows/release.yml`): push a `v*` tag (`git tag v0.0.1 && git push origin v0.0.1`) → builds the **universal** release APK + **split-per-abi** APKs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) + AAB on `ubuntu-latest` and the unsigned iOS IPA (`DreamPlayer.ipa` — name deliberately omits "unsigned") on `macos-latest`, then creates the GitHub Release on the tag with `.github/release_notes.md` (Android architecture guide + iOS sideload guide) plus auto-generated change notes, and attaches all artifacts. Android artifacts are renamed `DreamPlayer-<version>-universal.apk`, `DreamPlayer-<version>-<arch>.apk`, `DreamPlayer-<version>.aab`. App version is **0.1.8** (`pubspec.yaml` `version: 0.1.8+1` → Android versionName/versionCode + iOS CFBundleShortVersionString/CFBundleVersion) and must be bumped per release to match the tag. Android APKs are currently **debug-signed** (`build.gradle.kts` uses the debug signing config for release builds) — fine for sideloading, but add a real signing config before Play Store / wide distribution.
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
flutter run --dart-define-from-file=.env   # run on Android phone (USB) — the gitignored .env carries API keys
flutter run --release    # test real-world smoothness (debug is jankier)
flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=.env && flutter install --debug -d <device-id>
flutter build apk        # release APK (use --split-per-abi; TMDB key via --dart-define-from-file=.env)
flutter build appbundle  # for Play Store
adb shell monkey -p com.dreamplayer.app -c android.intent.category.LAUNCHER 1   # launch app
adb shell dumpsys SurfaceFlinger | grep -a activeMode                                  # check refresh rate
```

## Display & smoothness (native refresh rate)

- **Android**: `flutter_displaymode` selects the display's highest refresh rate at app startup (`lib/services/display_refresh_rate.dart`). Many Android devices default apps to 60 Hz even on 90/120/144 Hz panels. Verified: panel runs 120 Hz during animations, 60 Hz when idle.
- **iOS/iPad Pro**: ProMotion 120 Hz is unlocked via `CADisableMinimumFrameDurationOnPhone = true` in `ios/Runner/Info.plist` (already set).
- **Playback cadence**: ExoPlayer renders at the video's FPS onto the platform-view SurfaceView. Revisit frame pacing once smoothness is assessed on-device.
- **DEBUG BUILDS JITTER — always judge smoothness on a RELEASE build (2026-08, Redmi Note 10)**: 4K60 HDR playback in the **debug** APK showed periodic dropped frames while moneytoo's Just Player (release) was buttery smooth — but the ExoPlayer `DecoderCounters` showed `rendered=60fps steady, droppedBuffer=0` and SF `--latency` cadence was clean (0 double/triple frame gaps over 60 s; the only inevitable artefact is the 59.94-on-60 Hz beat, ~1 double frame per 16.7 s, present in both apps). The jitter was Flutter **debug-mode** overhead (JIT VM + hybrid-composition platform-view per-frame cost), not the decode/render path. Installing the **release** APK made it play as smooth as Just Player (user-verified). When the user reports "dropped frames" against a debug install, first re-test with `flutter build apk --release --dart-define-from-file=.env` + `flutter install` before touching the player code. Same rule as the `flutter run --release` comment below.

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
  services/exo_player.dart        # ExoPlayerController + ExoPlayerView platform view (hybrid composition on Android)
  services/continue_watching.dart # continue-watching list (shared_preferences JSON)
  services/jellyfin_client.dart     # Jellyfin/Emby REST + mDNS discovery + JellyfinServer/JellyfinItem/JellyfinItemInfo models + videoItem/serverForUrl/getItemInfo helpers + folder-meta cache
  services/tmdb_client.dart        # TMDB: filename parser (ParsedFileName), TmdApi (search/details/bestForQuery), TmdStore cache, TmdService facade
  services/library_folders.dart    # user-added library folders (LibraryFolder model + LibraryFoldersStore, prefs dreamplayer.libraryFolders; LibraryFolderSource.files|jellyfin)
  services/webdav_client.dart     # WebDAV channel wrapper + WebDavServer model (channel dreamplayer/webdav)
  config/tmdb_api_key.dart        # default TMDB key from --dart-define=TMDB_API_KEY (never committed)
  screens/
    home_screen.dart            # Continue watching grid (adaptive columns) + Your-library folder grid + **+** FAB menu (Jellyfin / WebDAV / Add folder / Internal storage)
    folder_screen.dart          # folder contents / episode list (subfolder navigation, SxxExx labels + sizes)
    player_screen.dart          # ExoPlayer/Media3 playback + live codec/HDR chips + controls + subtitle/audio pickers
    tmd_details_screen.dart     # TMDB details: backdrop/poster/synopsis/rating/genres/cast + Play + Fix match search
    jellyfin_screen.dart        # Jellyfin/Emby server list + 7359-probe/mDNS discovery + login + libraries → folders → play
    webdav_screen.dart          # WebDAV server list → folders → play (add/edit/delete servers, self-signed toggle)
    settings_screen.dart        # settings list
  widgets/
    video_card.dart             # library card with HDR/audio badges
    folder_card.dart            # library folder card (TMDB poster or gradient placeholder + TV/Movie badge)
    format_chip.dart            # colored codec/HDR chip
android/app/src/main/kotlin/com/dreamplayer/app/
  ExoPlayerView.kt              # native PlayerView platform view + channels (open/play/seek/tracks/subtitles) + OkHttp permissive DataSource for self-signed WebDAV
  SubtitleFormats.kt            # extension->MIME map, sibling auto-pairing, charset detection, UTF-8 re-encode
  DreamSubtitleParserFactory.kt # SAMI/MicroDVD/MPL2/SubViewer parsers + default delegate
  FileBrowser.kt                # device storage browsing channel (roots/listing/folder bookmarks; no thumbnails)
  WebDAVClient.kt               # WebDAV browse/test channel; encrypted password storage; friendly errors
  MulticastLockManager.kt       # Wi-Fi MulticastLock + Jellyfin UDP-7359 broadcast probe (channel dreamplayer/multicast)
  MainActivity.kt               # registers platform views + "Open with" intent handling
ios/Runner/
  AvPlayerView.swift            # AetherEngine platform view + channels (same contract as ExoPlayerView.kt); host SubtitleOverlayView; WebDAV http(s) streams with headers/self-signed via WebDAVByteRangeSource
  BufferedSMBReader.swift       # read-ahead sliding-window IOReader (32 MiB) for WebDAV playback
  JellyfinDiscovery.swift       # Jellyfin UDP-7359 broadcast probe (channel dreamplayer/multicast, discoverJellyfin; Android: MulticastLockManager.kt)
  WebDAVClient.swift            # WebDAV browse/test channel (same contract as WebDAVClient.kt); Keychain passwords; WebDAVByteRangeSource for playback
  FileBrowser.swift             # Documents-folder browsing channel (same contract as FileBrowser.kt); resolveImportedPath
  IntentBridge.swift            # "Open with" intent channel (same contract as MainActivity.kt)
  AppDelegate.swift             # registers the AvPlayerView factory + files/intent/webdav channels
  SceneDelegate.swift           # forwards scene-opened URLs to IntentBridge
test/
  widget_test.dart              # shell/navigation/overflow tests
  codec_info_test.dart          # HDR + codec formatting unit tests
  tmdb_test.dart                # TMDB filename parser + metadata store round-trip + API key fallback tests
```

## Workflow for the user (no Mac)

1. Develop + test on Android phone (USB debugging, `flutter run --dart-define-from-file=.env`).
2. Commit/push to `main`; iOS workflow in GitHub Actions builds the iPad version.
3. Later: configure code-signing secrets + TestFlight for installing on iPad Pro M2.
