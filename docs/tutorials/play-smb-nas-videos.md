# Playing SMB / NAS videos with DreamPlayer

**Video walkthrough (iOS):** [YouTube Short](https://youtube.com/shorts/a7oR1yxGz2o)

DreamPlayer has no in-app SMB browser anymore (it was hidden in 2026-08 — switching
audio tracks on an SMB stream could crash the app). Instead, NAS playback goes
through the **Files app's built-in SMB support** and DreamPlayer's **"Open with"** / file-browser
integration. Videos play exactly like any other file DreamPlayer receives — HDR/codec chips,
subtitle picker, resume, everything works.

## On iPhone / iPad

### Option A — connect your NAS in the Files app, then "Open with"

1. **Connect the NAS in Files:**

   <img src="images/1.%20connect_to_server.png" alt="Connect to Server in the Files app" width="360" align="center"/>

   - Open the **Files** app → **Browse** (sidebar) → tap the **⋯** menu at the top → **Connect to Server**.
   - Enter your server address, e.g. `smb://192.168.1.50` or `smb://nas.local`.
   - Pick **Registered User** (your NAS username/password) or **Guest**, tap **Next**, and the
     share appears in the Files sidebar under **Locations**.
2. **Browse to a video** inside the share. SMB streams are lazy — Files only downloads what it
   needs, so you can browse a huge library without copying it.
3. **Long-press the video → Share → Open in "DreamPlayer"** (or **Copy to** → **DreamPlayer**).
   DreamPlayer appears in the share sheet for all video containers (mkv, ts, m2ts, webm, wmv,
   flv, mpg… plus the standard video/* types).
4. Playback starts immediately; tap **⋮ / audio** during playback to switch audio tracks.

> Tip: for a *folder* of episodes, use **Option B** once and the folder stays bookmarked.

### Option B — bookmark the NAS folder in DreamPlayer's file browser

If you play from the same NAS folder often, bookmark it once:

1. Do **Option A step 1** (connect the server in Files — see the first image above).

2. Open **DreamPlayer → Folder icon (top-right)**:

   <img src="images/2.%20open_app_and_click_folder_icon.png" alt="Open DreamPlayer and tap the folder icon" width="360" align="center"/>

3. Tap **Pick a folder**:

   <img src="images/3.%20click_pick_folder.png" alt="Tap Pick a folder" width="360" align="center"/>

4. In the system folder picker, navigate into the connected **server** under Locations:

   <img src="images/4.%20select_connected_server.png" alt="Select the connected server" width="360" align="center"/>

5. Pick the video folder and tap **Open**. DreamPlayer bookmarks it (security-scoped, kept
   across launches):

   <img src="images/5.%20choose_folder_click_open.png" alt="Choose the folder and tap Open" width="360" align="center"/>

6. The folder now appears at the top of the file browser — browse and play any video in it, no
   per-file share sheet needed:

   <img src="images/6.%20play_file.png" alt="Browse and play any video in the bookmarked folder" width="360" align="center"/>

> Bookmarked folders keep their access across launches (iOS security-scoped bookmarks are stored
> in UserDefaults). Remove a bookmark with the **×** beside it at the browser root.

### Option C — WebDAV / FTP servers (via a third-party client)

The Files app's **"Connect to Server" is SMB only** — it cannot connect to WebDAV or FTP servers
natively. For those, use a third-party client and hand the file to DreamPlayer:

1. Install a WebDAV client such as **[Documents by Readdle](https://apps.apple.com/app/documents-file-manager-docs/id364901807)** (free),
   **WebDAV Nav+**, or **FE File Explorer**, and connect it to your server (e.g.
   `https://my-nas.local/dav`, username + password).
2. Browse to a video in the client. SMB/WebDAV streams are lazy, so you can browse a huge
   library without copying it.
3. **Long-press the video → Share → Open in "DreamPlayer"** (or **Open with → DreamPlayer**).
   DreamPlayer appears in the share sheet for all video containers (mkv, ts, m2ts, webm, wmv,
   flv, mpg… plus the standard video/* types).
4. Playback starts immediately; tap **⋮ / audio** during playback to switch audio tracks.

> Tip: in **Documents by Readdle**, enable **"Use as Storage Provider"** for the WebDAV
> connection — the server then also appears in the Files app under **Locations**, so you can
> browse it from Files too (still hand the video to DreamPlayer via Share → Open in).

## On Android (CX Explorer → "Open with")

Android has no in-app SMB browser either. The supported NAS path:

1. In **CX Explorer**, connect to the SMB share and browse to a video.
2. **Tap the video → Open with → DreamPlayer.** CX streams the file over a local HTTP proxy
   (`http://127.0.0.1:<port>/SMB/...`); DreamPlayer plays it at full speed (4K HEVC verified
   at 60 fps, 0 dropped frames). Tap the **audio** button to switch tracks.

## Troubleshooting

- **DreamPlayer doesn't appear in the share sheet / Open-with list:** on iOS ensure the video
  file hasn't been renamed to a non-video extension (`.mkv` needs the sidebar picker, which Files
  shows for known containers; for unusual containers check "Copy to" as well).
- **Video opens but shows a spinner:** on iOS the first open of a large NAS file may stage some
  data through Files; give it a few seconds. If it persists, the Wi-Fi link can't sustain the
  bitrate — lower-bitrate or network-side fixes apply.
- **Bookmarked folder disappears after an iPad restart:** iOS security-scoped bookmarks can expire
  if the app wasn't opened for a long time; re-pick the folder once.
