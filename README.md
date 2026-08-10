# DreamPlayer

A cross-platform video player built with **Flutter**, designed for high-end playback on Android and iOS/iPad — including **Dolby Vision**, HDR10/HDR10+, and lossless audio formats like DTS-HD and TrueHD.

> **Android (primary):** playback runs on the native **ExoPlayer / Media3** engine inside a Flutter platform view, so the display receives a real HDR / Dolby Vision signal (no tone-mapped preview).
> **iOS/iPad:** coming soon (native AVPlayer path).

## Features

- **Dolby Vision playback** — DV P8 verified on-device: decoded by the Qualcomm hardware `c2.qti.dv.decoder` at 4K 3840×2160@60 fps with zero dropped frames and correct colors.
- **HDR on-screen display** — live chips for Dolby Vision, HDR10+, HDR10, HLG, SDR.
- **All major audio codecs** — DTS, DTS-HD, E-AC3, AC3, TrueHD, AAC, and more via Media3 `FFmpegAudioRenderer` (FLAC and E-AC3 work around buggy platform decoders).
- **Audio track selection** — pick any audio track mid-playback; the sheet shows the full track name and channels (e.g. `DTS-HD MA 5.1`).
- **SMB / LAN playback** — add NAS servers (encrypted credentials), scan the network, browse shares, and stream videos directly with no download; full seek, play-next-episode, auto-paired subtitles, and a 96 MB read-ahead buffer for smooth 4K over Wi-Fi.
- **In-app file browser** — browse the whole device and play any video, no import needed.
- **"Open with" integration** — tap any video on the device and open it in DreamPlayer; works with file managers like CX Explorer (including their network-stream handoff via a local HTTP proxy).
- **Live codec / resolution overlay** — video codec, audio codec + channel count, resolution, HDR format as the file plays.
- **Transport controls** — play/pause, seek bar, ±10s, fullscreen, buffering spinner, auto-hiding UI.
- **Native refresh rate** — selects the display's highest refresh rate (e.g. 120 Hz) at startup.

## Tech stack

| Concern | Choice |
|---|---|
| Framework | Flutter (stable 3.44.x) |
| Playback engine (Android) | ExoPlayer / Media3 in a native `SurfaceView` PlatformView |
| Video decode | Android MediaCodec (hardware DV/HEVC/AVC; `c2.qti.dv.decoder` on device) |
| Audio decode | Media3 `FFmpegAudioRenderer` extension (`libmedia3ext.so`) |
| SMB / LAN | jcifs-ng (SMB2/3) for browsing + a custom ExoPlayer `DataSource` for streaming |
| HDR output | Hybrid-composition PlatformView keeps its own SurfaceFlinger layer → real HDR to the display |
| Reference architecture | [Nova Video Player](https://github.com/nova-video-player/aos-AVP) |
| Permissions | `permission_handler` (runtime `READ_MEDIA_VIDEO`); `MANAGE_EXTERNAL_STORAGE` for the file browser |
| Refresh rate | `flutter_displaymode` |

## Getting started

```bash
flutter pub get
flutter run                          # run on a connected Android phone
flutter test                         # run tests
flutter analyze                      # static analysis
```

Build a debug APK for your phone:

```bash
flutter build apk --debug --target-platform android-arm64
flutter install --debug -d <device-id>
```

## Project layout

```
lib/
  main.dart                     # entry point (native refresh rate)
  app.dart                      # root MaterialApp, dark theme, nav shell
  theme/app_theme.dart          # dark theme
  models/
    video_item.dart             # library item model + codec labels
    hdr_format.dart             # HDR format enum
  utils/codec_info.dart         # HDR detection + codec → label mapping
  services/
    display_refresh_rate.dart   # high refresh rate selection
    exo_player.dart             # ExoPlayerController + ExoPlayerView platform view
    smb_client.dart             # SMB server/share models + channel wrapper
    file_browser.dart           # file-browser channel wrapper
    open_intent.dart            # "Open with" intent bridge
  screens/
    home_screen.dart            # library (empty state until scanning lands)
    player_screen.dart          # ExoPlayer playback + live chips + controls
    smb_screen.dart             # SMB server list → shares → folders
    file_browser_screen.dart    # in-app device file browser
    settings_screen.dart        # settings
  widgets/
    video_card.dart             # library card with HDR/audio badges
    format_chip.dart            # colored codec/HDR chip
android/app/src/main/kotlin/com/example/dream_player/
  ExoPlayerView.kt              # native PlayerView platform view + channels
  SmbDataSource.kt              # ExoPlayer DataSource (SMB streaming + http proxy)
  SMBClient.kt                  # SMB browsing/discovery/status + encrypted store
  FileBrowser.kt                # device storage browsing channel
  MainActivity.kt               # registers platform views + intent handling
test/
  widget_test.dart              # shell/navigation/overflow tests
  codec_info_test.dart          # HDR + codec formatting tests
```

## Roadmap

- [x] Android playback via ExoPlayer/Media3 PlatformView
- [x] Dolby Vision + lossless audio on-device (DV P8, E-AC3)
- [x] Remove mpv/media_kit (cannot output Dolby Vision)
- [x] SMB/LAN playback v1 (browse, stream, discovery, subtitles, play-next)
- [ ] iOS/iPad playback (AVPlayer)
- [ ] MediaStore scanning for the library
- [ ] Release build + Play Store / TestFlight distribution

## License

This project is for personal use. Media3 is licensed under the Apache 2.0 license; the bundled FFmpeg extension (`nextlib-media3ext`) is GPLv3.
