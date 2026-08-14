# Changelog

All notable changes to DreamPlayer are documented here. Each release's entry is
pulled into the GitHub Release body automatically by `.github/workflows/release.yml`.

## 0.0.8

- **Source badges on Continue watching cards** — every card shows where the video
  plays from: WebDAV, CX SMB, Files/SMB, Files, or Network (colored badge,
  bottom-left).
- **iOS "Files" home** — the file browser's root now has a **Files** folder that
  opens the system Files-app home (iCloud Drive, On My iPad, Downloads, other
  providers); pick a video and it plays. The Documents folder and bookmarked
  folders stay listed below it.
- **Stable resume keys for network sources** — CX Explorer SMB handoffs resume by
  their stable path (`cx:` key) and iOS bookmarked-folder files by a remount-safe
  `folderbookmark:` key, so Continue watching keeps working even when the source
  URL rotates between sessions.
- **WebDAV browsing + playback (Android + iPad)** — add/edit/delete servers with an
  inline connection test, browse folders and stream videos straight into the
  player; credentials stored encrypted (Android Keystore / iOS Keychain),
  per-server self-signed HTTPS opt-in (default off), friendly plain-language
  errors.
- **iOS WebDAV folder listing fix** — multistatus XML is now parsed with namespace
  processing, so Apache/nginx/Nextcloud/Synology servers list folders correctly
  (the empty "Nothing here" was a silent parse failure, not an auth problem).
- **Card redesign** — home cards show the gradient/play-icon placeholder plus
  Continue-watching progress and source info (thumbnail extraction removed).

## 0.0.7

- **In-app SMB home entry hidden on all platforms** — NAS playback now goes through
  CX Explorer → "Open with" (Android) and the Files app → "Open with" / bookmarked
  folders (iPad), which cover local + NAS workflows without the audio-track-switch
  crash. The SMB code stays in the tree as a rebuild blueprint.
- Added an SMB/NAS playback tutorial with screenshots and a video walkthrough.

## 0.0.6

- **iPad SMB playback hardened** — SMB streams now load through a read-ahead
  sliding-window reader (`BufferedSMBReader`, 32 MiB) so Wi-Fi latency no longer
  triggers the buffering spinner mid-playback; audio-track switching on SMB
  streams reopens the session with a fresh connection (EPERM fix); AetherEngineSMB
  is linked correctly as a static SPM product.

## 0.0.4

- **iPad in-app SMB playback** via AetherEngineSMB — SMB shares browse and stream
  directly through the engine's custom `IOReader` source (AMSMB2 browse client).

## 0.0.3

- iPad SMB playback fixes — ATS local-network allowance, stream-URL extension +
  content type, and a synchronous connect before returning the URL.

## 0.0.2

- **Android playback via ExoPlayer/Media3** in a native `SurfaceView` PlatformView
  with real Dolby Vision output (`c2.qti.dv.decoder`, verified 4K@60 with zero
  dropped frames) and live HDR/codec/resolution chips.
- **iOS/iPad playback via AetherEngine** (FFmpeg demux/decode + native DV/HDR path)
  behind the same platform-view contract.
- **Subtitles** — embedded + sideloaded (SRT, ASS, WebVTT, TTML, SAMI, MicroDVD,
  MPL2, SubViewer) auto-paired from the video's folder, with a full track picker.
- **Audio track selection** — full track names and channels (e.g. DTS-HD MA 5.1);
  FLAC and E-AC3 work around buggy platform decoders via the bundled FFmpeg
  renderer.
- **In-app file browser** (Android storage / iPad Files folders), **"Open with"**
  integration (including CX Explorer's network-stream handoff), **resume playback**,
  **native refresh rate**, dark theme.
