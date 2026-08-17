import AVFoundation
import AetherEngine
import AetherEngineSMB
import Combine
import Flutter
import UIKit

/// Subtitle overlay drawn by the host (AetherEngine decodes cues into
/// `engine.$subtitleCues`; the engine's `AetherPlayerView` does not paint them).
/// Text and bitmap cues are positioned against the aspect-fit video rect, and
/// `layoutSubviews` re-runs on rotation/resize so a cue keeps hugging the video
/// even mid-cue instead of drifting to the letterbox edge.
private final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    private let imageView = UIImageView()
    /// Coded video size (points-independent) used to compute the aspect-fit rect.
    fileprivate var videoSize: CGSize = .zero
    private var activeText: String?
    private var activeImage: SubtitleImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The engine re-attaches the video layer on every session swap, which
        // re-adds it above sibling subviews; pinning our z-order keeps cues on top.
        layer.zPosition = 1000

        label.isHidden = true
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.shadowColor = .black
        label.shadowOffset = CGSize(width: 1, height: 1)
        addSubview(label)

        imageView.isHidden = true
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionActiveCue()
    }

    func show(text: String) {
        activeText = text.isEmpty ? nil : text
        activeImage = nil
        label.text = text
        imageView.isHidden = true
        setNeedsLayout()
    }

    func show(image: SubtitleImage) {
        activeImage = image
        activeText = nil
        imageView.image = UIImage(cgImage: image.cgImage)
        imageView.isHidden = false
        label.isHidden = true
        setNeedsLayout()
    }

    func clear() {
        activeText = nil
        activeImage = nil
        label.isHidden = true
        imageView.isHidden = true
    }

    private func positionActiveCue() {
        if let image = activeImage {
            position(image: image)
        } else if let text = activeText {
            position(text: text)
        } else {
            label.isHidden = true
            imageView.isHidden = true
        }
    }

    private func position(text: String) {
        guard !text.isEmpty else {
            label.isHidden = true
            return
        }
        label.isHidden = false
        imageView.isHidden = true
        let rect = videoRect(in: bounds)
        let maxWidth = max(rect.width - 32, 40)
        let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let width = min(size.width, maxWidth)
        label.frame = CGRect(
            x: rect.midX - width / 2,
            y: rect.maxY - size.height - 12,
            width: width,
            height: size.height
        )
    }

    private func position(image: SubtitleImage) {
        guard imageView.image != nil else { return }
        imageView.isHidden = false
        label.isHidden = true
        let rect = videoRect(in: bounds)
        let p = image.position
        // `position` is normalized [0,1] against the subtitle canvas (usually
        // the coded video). A cropped rip can carry a taller canvas than the
        // video, so map canvas -> video width-aligned and center-anchored,
        // mirroring the engine's own SubtitleFrameCompositor mapping.
        let c = image.canvasSize
        let frame = CGRect(origin: .zero, size: rect.size)
        let r: CGRect
        if c.width > 0, c.height > 0 {
            let px = p.minX * c.width
            let py = p.minY * c.height
            let scale = frame.width / c.width
            r = CGRect(
                x: px * scale,
                y: frame.height / 2 + (py - c.height / 2) * scale,
                width: p.width * c.width * scale,
                height: p.height * c.height * scale
            )
        } else {
            r = CGRect(
                x: p.minX * frame.width,
                y: p.minY * frame.height,
                width: p.width * frame.width,
                height: p.height * frame.height
            )
        }
        imageView.frame = r.offsetBy(dx: rect.minX, dy: rect.minY)
    }

    /// Aspect-fit rect of the video within the overlay's bounds.
    private func videoRect(in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let aspect = videoSize.width / videoSize.height
        let viewAspect = bounds.width / max(bounds.height, 1)
        if viewAspect > aspect {
            // View is wider than the video: fills the height, bars left/right.
            let w = bounds.height * aspect
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        } else {
            // View is taller than the video: fills the width, bars top/bottom.
            let h = bounds.width / aspect
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        }
    }
}

/// Factory registered for `dreamplayer/exo_player` on iOS (see AppDelegate).
final class AvPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        // UIKit platform views are created on the platform (main) thread, so the
        // MainActor-isolated AvPlayerView init is safe to assume here.
        MainActor.assumeIsolated {
            AvPlayerView(messenger: messenger, viewId: viewId, frame: frame)
        }
    }
}

/// AetherEngine-backed platform view mirroring the Android ExoPlayer contract:
/// same channel names (`dreamplayer/exo_<id>`, `dreamplayer/exo_events_<id>`),
/// same method names, same event map keys, so the Dart `ExoPlayerController`
/// works unchanged on both platforms.
///
/// AetherEngine gives iOS what AVPlayer alone cannot: FFmpeg demux of MKV /
/// TS / AVI / WebM, DTS / DTS-HD / TrueHD / E-AC3 decode (AudioToolbox +
/// libavcodec), and real Dolby Vision / HDR10(+) via the native AVPlayer path
/// for Apple containers. Embedded and sideloaded subtitle tracks (SRT / ASS /
/// VTT sidecars auto-paired from the video's folder) are listed through the
/// same `subtitleTracks` / `selectSubtitleTrack` contract.
@MainActor
final class AvPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler {

    private let container: AetherPlayerView
    private let subtitleOverlay: SubtitleOverlayView
    private let engine: AetherEngine?

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // ---- Source facts (captured from the load probe). ----
    private var videoCodecName: String?
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    private var isDolbyVision = false
    private var dvProfile: Int?

    private var lastError: String?
    private var pendingAutoSubtitleIndex: Int?
    private var savedVolume: Float = 1
    private var isMuted = false

    // ---- Last-opened source (needed to reload when the engine parks in .ended). ----
    private var lastSource: MediaSource?
    private var lastLoadOptions = LoadOptions()

    // ---- SMB stream (see SMBClient.openShare). Kept so an audio-track switch
    // reopens with a FRESH SMBIOReader on a FRESH connection: the engine's
    // retained-reader reload (keepCustomReader) reuses one SMBIOReader whose
    // cancel() from the old session teardown can poison the new probe's first
    // read (returns -1 → EPERM "Demuxer: open failed"). ownsSource: false so
    // the engine closing the previous reader doesn't tear down the shared
    // SMBConnection (SMBClient owns its lifetime). ----
    private var smbToken: String?
    private var isSMBStream = false
    /// File extension from the SMB token URL, passed to AetherEngine as a
    /// `formatHint` so FFmpeg skips the byte-level probe.  `nil` for
    /// extensionless files (e.g. "stream" fallback in `openShare`).
    private var smbFormatHint: String?
    /// Stale SMBConnections from the last audio-track switch (primary + extras).
    /// Kept alive until the NEXT switch or teardown so AetherEngine's FFmpeg
    /// demux thread can finish draining I/O without sockets being torn down.
    private var previousStaleSMBConnections: [SMBConnection] = []

    init(messenger: FlutterBinaryMessenger, viewId: Int64, frame: CGRect) {
        container = AetherPlayerView(frame: frame)
        subtitleOverlay = SubtitleOverlayView(frame: container.bounds)
        subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        engine = try? AetherEngine()
        methodChannel = FlutterMethodChannel(name: "dreamplayer/exo_\(viewId)", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "dreamplayer/exo_events_\(viewId)", binaryMessenger: messenger)
        super.init()

        container.backgroundColor = .black
        container.addSubview(subtitleOverlay)

        if let engine {
            engine.bind(view: container)
            observeEngine(engine)
        }

        eventChannel.setStreamHandler(self)

        methodChannel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                let args = call.arguments as? [String: Any]
                switch call.method {
                case "open":
                    self.open(args, result)
                case "play":
                    // .ended is terminal in AetherEngine (seek/play no-op there), so
                    // replay = reload the last source from the start.
                    if self.engine?.state == .ended {
                        await self.reloadSession(at: 0)
                    } else {
                        self.engine?.play()
                    }
                    self.emit()
                    result(nil)
                case "pause":
                    self.engine?.pause()
                    result(nil)
                case "seekTo":
                    let ms = (args?["positionMs"] as? NSNumber)?.int64Value ?? 0
                    if self.engine?.state == .ended {
                        // Pulling the scrubber back after end-of-media: reload at the
                        // requested position instead of seeking a parked session.
                        await self.reloadSession(at: Double(ms) / 1000.0)
                    } else {
                        await self.engine?.seek(to: Double(ms) / 1000.0)
                    }
                    self.emit()
                    result(nil)
                case "setVolume":
                    let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 1
                    self.savedVolume = min(max(volume, 0), 1)
                    if !self.isMuted { self.engine?.volume = self.savedVolume }
                    result(nil)
                case "setMuted":
                    self.isMuted = (args?["muted"] as? Bool) ?? false
                    self.engine?.volume = self.isMuted ? 0 : self.savedVolume
                    result(nil)
                case "getAudioTracks":
                    result(self.audioTrackMaps())
                case "getState":
                    // Push a fresh snapshot to the event stream and return the
                    // current state; Dart uses it after a background/foreground
                    // cycle to decide whether to reopen the media.
                    self.emit()
                    result(self.stateMap())
                case "setAudioTrack":
                    let index = (args?["index"] as? NSNumber)?.intValue ?? -1
                    if self.isSMBStream {
                        // The engine's selectAudioTrack reload reuses the RETAINED
                        // SMBIOReader; its teardown cancel() can poison the new probe's
                        // first read (EPERM "Demuxer: open failed"). Reopen with a
                        // FRESH connection + reader and select the stream via
                        // load(audioSourceStreamIndex:) instead.
                        await self.reopenSMBStream(audioIndex: index)
                    } else {
                        self.engine?.selectAudioTrack(index: index)
                    }
                    result(nil)
                case "setSubtitles":
                    let on = (args?["on"] as? Bool) ?? true
                    self.setSubtitles(on)
                    result(nil)
                case "getSubtitleTracks":
                    result(self.subtitleTrackMaps())
                case "setSubtitleTrack":
                    let index = (args?["index"] as? NSNumber)?.intValue ?? -1
                    self.selectSubtitleTrack(index)
                    result(nil)
                case "setResizeMode":
                    let mode = (args?["mode"] as? NSNumber)?.intValue ?? 0
                    self.setResizeMode(mode)
                    result(nil)
                case "dispose":
                    self.teardownAll()
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        }
    }

    // MARK: - FlutterPlatformView

    func view() -> UIView { container }

    func dispose() {
        teardownAll()
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        startTickTimer()
        emit()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stopTickTimer()
        return nil
    }

    // MARK: - Engine observation

    private func observeEngine(_ engine: AetherEngine) {
        engine.$state.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$isBuffering.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$duration.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$audioTracks.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$subtitleTracks.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$activeAudioTrackIndex.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$activeSubtitleTrackIndex.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)
        engine.$videoFormat.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }.store(in: &cancellables)

        engine.clock.$sourceTime.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSubtitleOverlay() }
        }.store(in: &cancellables)
        engine.$subtitleCues.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSubtitleOverlay() }
        }.store(in: &cancellables)
    }

    // MARK: - Playback

    private func open(_ args: [String: Any]?, _ result: FlutterResult) {
        guard let engine else {
            result(FlutterError(code: "engine_init", message: "AetherEngine failed to initialize", details: nil))
            return
        }
        let path = args?["path"] as? String
        let uri = args?["uri"] as? String
        let subtitleUri = args?["subtitleUri"] as? String
        let startMs = (args?["startPositionMs"] as? NSNumber)?.int64Value ?? 0
        // HTTP request headers (e.g. WebDAV Basic auth) + per-server self-signed
        // opt-in, both per media item at open time (same contract as Android).
        let httpHeaders = (args?["headers"] as? [String: String]) ?? [:]
        let allowSelfSigned = (args?["allowSelfSigned"] as? Bool) ?? false

        // SMB streams arrive as `dreamplayersmb://<token>.<ext>` (see
        // SMBClient.openShare): resolve the token to the live SMBConnection
        // and load it as a custom IOReader source. AetherEngine's FFmpeg has no
        // network stack, so a loopback HTTP bridge is the wrong shape — this is
        // the engine's native SMB path (AetherEngineSMB).
        var source: MediaSource?
        var localURL: URL?
        // WebDAV source pending construction: `makeByteRangeSource` does a
        // blocking size probe, so it must run off the main thread — the async
        // load task below builds it.
        var webDAVSource: (url: URL, headers: [String: String], allowSelfSigned: Bool)?
        smbToken = nil
        isSMBStream = false
        smbFormatHint = nil
        if let path, !path.isEmpty {
            localURL = URL(fileURLWithPath: path)
            source = .url(localURL!)
        } else if let uri, let parsed = Self.smbToken(in: uri) {
            let conns = SMBClient.shared.connections(for: parsed.token)
            guard !conns.isEmpty else {
                result(FlutterError(code: "smb_stream", message: "SMB stream token not found", details: nil))
                return
            }
            // Multi-thread parallel prefetch: each connection is an independent
            // TCP socket to the NAS.  BufferedSMBReader's 4 prefetch tasks each
            // read from their own connection simultaneously, filling a 96 MiB
            // ring buffer ahead of the cursor.
            smbToken = parsed.token
            isSMBStream = true
            if parsed.ext.isEmpty || parsed.ext == "stream" {
                // Extensionless file on the NAS (e.g. "LG") — read the first
                // 16 bytes and guess the container so FFmpeg doesn't fail its
                // byte-level probe with "custom probe failed".
                smbFormatHint = Self.sniffFormatFromSMB(conns[0])
                print("smb-sniff: extensionless -> \(smbFormatHint ?? "nil")")
            } else {
                smbFormatHint = parsed.ext
            }
            source = .custom(
                BufferedSMBReader(sources: conns),
                formatHint: smbFormatHint
            )
        } else if let uri, let u = URL(string: uri),
                  (u.scheme?.lowercased() == "http" || u.scheme?.lowercased() == "https"),
                  !httpHeaders.isEmpty || allowSelfSigned {
            // WebDAV playback: auth headers AND self-signed HTTPS can't go
            // through AetherEngine's own HTTP stack (no headers API, and its
            // TLS validation can't be bypassed), so serve the stream as a
            // custom ByteRangeSource — each read is an independent HTTP Range
            // request carrying the Authorization header on the permissive or
            // default-trust session. Wrapped in BufferedSMBReader for the same
            // read-ahead reason as SMB (the loopback producer starves on
            // per-read network round-trips). The source is stateless per read,
            // so the engine's internal reload on audio-track switch is safe.
            localURL = u
            webDAVSource = (u, httpHeaders, allowSelfSigned)
        } else if let uri, let u = URL(string: uri) {
            localURL = u
            source = .url(u)
        } else {
            result(FlutterError(code: "bad_args", message: "Missing path or uri", details: nil))
            return
        }

        // Play audio even with the mute switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true

        // Reset per-open state.
        lastError = nil
        pendingAutoSubtitleIndex = nil
        videoCodecName = nil
        videoWidth = 0
        videoHeight = 0
        isDolbyVision = false
        dvProfile = nil
        subtitleOverlay.clear()
        emit()

        // Sidecar subtitles: an explicit `subtitleUri` wins; otherwise auto-pair
        // sibling files in the video's folder (best match first, like Android).
        var externals: [ExternalSubtitleTrack] = []
        if let subtitleUri, !subtitleUri.isEmpty, let sub = Self.url(for: subtitleUri) {
            externals.append(ExternalSubtitleTrack(url: sub, isDefault: true, formatHint: sub.pathExtension.lowercased()))
            pendingAutoSubtitleIndex = AetherEngine.externalSubtitleTrackIDBase + 0
        } else if let localURL, localURL.isFileURL {
            externals = Self.siblingSubtitles(for: localURL)
            if let best = externals.firstIndex(where: { $0.isDefault }) {
                pendingAutoSubtitleIndex = AetherEngine.externalSubtitleTrackIDBase + best
            }
        }

        let options = LoadOptions(
            httpHeaders: [:],
            panelIsInHDRMode: UIScreen.main.currentEDRHeadroom > 1.0,
            preferredAudioLanguages: [],
            preferredSubtitleLanguages: [],
            externalSubtitles: externals,
            autoplay: true
        )
        lastSource = source
        lastLoadOptions = options
        // Resume: continue from the last watched position when the caller asks.
        let startPosition: Double? = startMs > 0 ? Double(startMs) / 1000.0 : nil

        Task { @MainActor [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                if let (webURL, webHeaders, webAllowSelfSigned) = webDAVSource {
                    // Size probe is a blocking URLSession round-trip; keep it
                    // off the main actor.
                    let byteSource = try await Task.detached(priority: .userInitiated) {
                        try WebDAVClient.shared.makeByteRangeSource(
                            url: webURL,
                            headers: webHeaders,
                            allowSelfSigned: webAllowSelfSigned
                        )
                    }.value
                    let ext = webURL.pathExtension.lowercased()
                    source = .custom(
                        BufferedSMBReader(source: byteSource),
                        formatHint: ext.isEmpty ? nil : ext
                    )
                }
                guard let finalSource = source else {
                    self.lastError = "Missing media source"
                    self.emit()
                    return
                }
                self.lastSource = finalSource
                let probe = try await engine.load(source: finalSource, startPosition: startPosition, options: options)
                if let probe {
                    self.videoCodecName = probe.videoCodecName
                    self.videoWidth = Int(probe.videoWidth)
                    self.videoHeight = Int(probe.videoHeight)
                    self.isDolbyVision = probe.isDolbyVision
                    self.dvProfile = probe.dvProfile
                }
                if let pending = self.pendingAutoSubtitleIndex,
                   engine.subtitleTracks.contains(where: { $0.id == pending }) {
                    engine.selectSubtitleTrack(index: pending)
                }
                self.pendingAutoSubtitleIndex = nil
                self.emit()
            } catch {
                self.lastError = String(describing: error)
                self.emit()
            }
        }
        result(nil)
    }

    /// Replays the last-opened source at `position` seconds. AetherEngine treats
    /// `.ended` as terminal (seek/play are no-ops there), so a replay / scrubber
    /// pull-back after the end card reloads the session instead.
    private func reloadSession(at position: Double) async {
        guard let engine, let lastSource else { return }
        let activeSub = engine.activeSubtitleTrackIndex
        do {
            let probe = try await engine.load(source: lastSource, startPosition: position, options: lastLoadOptions)
            if let probe {
                videoCodecName = probe.videoCodecName
                videoWidth = Int(probe.videoWidth)
                videoHeight = Int(probe.videoHeight)
                isDolbyVision = probe.isDolbyVision
                dvProfile = probe.dvProfile
            }
            if let activeSub, engine.subtitleTracks.contains(where: { $0.id == activeSub }) {
                engine.selectSubtitleTrack(index: activeSub)
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Audio-track switch on an SMB stream. AetherEngine's `selectAudioTrack`
    /// reload reuses the RETAINED custom `SMBIOReader`: its teardown `cancel()`
    /// marks the CURRENT in-flight read cancelled, so if it lands while the new
    /// probe is reading the same shared reader, that read aborts with -1
    /// (FFmpeg maps to EPERM, "Demuxer: open failed (Operation not
    /// permitted)"). A fresh SMBConnection per reopen sidesteps this entirely:
    /// `SMBClient.reconnect(for:)` mints a new transport, so no two sessions
    /// ever share an `SMBConnection` / `FileReader` mid-teardown.
    private func reopenSMBStream(audioIndex: Int) async {
        guard let engine, let smbToken else { return }
        guard audioIndex >= 0, engine.audioTracks.contains(where: { $0.id == audioIndex }) else { return }
        if engine.activeAudioTrackIndex == audioIndex { return }
        let activeSub = engine.activeSubtitleTrackIndex
        let resumeAt = engine.currentTime

        // Mint FRESH SMBConnections + BufferedSMBReader for the reload.
        // Do NOT call engine.stop() first — the initial open() works by
        // calling load() directly (which internally stops the old source),
        // and stop() + load() on the same engine can race: stop() signals
        // the demux thread to quit but returns before it fully releases the
        // old IOReader, so the new load()'s probe reads against a half-torn-
        // down source and gets EIO (-5). load() handles the transition itself.
        //
        // reconnectAll mints N fresh connections (one per prefetch thread)
        // and returns the stale extras from the previous session.
        let result = await Task.detached(priority: .userInitiated) {
            SMBClient.shared.reconnectAll(for: smbToken, count: 4)
        }.value
        guard let result else {
            lastError = "SMB stream reconnect failed for audio track switch"
            emit()
            return
        }
        let freshConns = result.fresh
        // Close stale connections from the PREVIOUS audio-track switch —
        // by now AetherEngine has fully released the old reader (the new
        // load() below replaces the demuxer synchronously).
        for conn in previousStaleSMBConnections { conn.close() }
        previousStaleSMBConnections = result.staleExtras
        let source: MediaSource = .custom(
            BufferedSMBReader(sources: freshConns),
            formatHint: smbFormatHint
        )
        lastSource = source
        do {
            let probe = try await engine.load(
                source: source,
                startPosition: resumeAt,
                options: lastLoadOptions,
                audioSourceStreamIndex: Int32(audioIndex)
            )
            if let probe {
                videoCodecName = probe.videoCodecName
                videoWidth = Int(probe.videoWidth)
                videoHeight = Int(probe.videoHeight)
                isDolbyVision = probe.isDolbyVision
                dvProfile = probe.dvProfile
            }
            if let activeSub, engine.subtitleTracks.contains(where: { $0.id == activeSub }) {
                engine.selectSubtitleTrack(index: activeSub)
            }
            emit()
        } catch {
            lastError = String(describing: error)
            emit()
        }
    }

    // MARK: - Fit / zoom mode

    /// Maps the Dart-side [VideoFitMode] to AVPlayerLayer videoGravity. The
    /// layer lives inside AetherEngine's `AetherPlayerView`; we locate it via
    /// the view hierarchy. Fixed ratios (16:9 / 4:3) are approximated with
    /// `.resizeAspectFill` (crop) — exact fixed-ratio boxes need the engine's
    /// own layout hooks, revisit on-device on the iPad.
    private func setResizeMode(_ mode: Int) {
        guard let playerLayer = findPlayerLayer() else { return }
        let gravity: AVLayerVideoGravity
        switch mode {
        case 1, 3, 4: gravity = .resizeAspectFill // crop / fixed ratios
        case 2: gravity = .resize // stretch
        default: gravity = .resizeAspect // fit
        }
        if playerLayer.videoGravity != gravity {
            playerLayer.videoGravity = gravity
        }
    }

    private func findPlayerLayer() -> AVPlayerLayer? {
        if let layer = container.layer as? AVPlayerLayer { return layer }
        return container.layer.sublayers?.lazy.compactMap { $0 as? AVPlayerLayer }.first
    }

    // MARK: - Track selection

    private func setSubtitles(_ on: Bool) {
        guard let engine else { return }
        if !on {
            engine.clearSubtitle()
        } else if let current = engine.activeSubtitleTrackIndex {
            engine.selectSubtitleTrack(index: current)
        } else if let first = engine.subtitleTracks.first {
            engine.selectSubtitleTrack(index: first.id)
        }
        emit()
    }

    private func selectSubtitleTrack(_ index: Int) {
        guard let engine else { return }
        if index >= 0, engine.subtitleTracks.contains(where: { $0.id == index }) {
            engine.selectSubtitleTrack(index: index)
        } else {
            engine.clearSubtitle()
        }
        emit()
    }

    // MARK: - Event emission

    private func startTickTimer() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func stateMap() -> [String: Any] {
        guard let engine else { return [:] }
        let state = engine.state

        let st: Int
        switch state {
        case .idle: st = 1
        case .loading, .seeking: st = 2
        case .playing, .paused: st = 3
        case .ended: st = 4
        case .error(let message):
            st = 1
            lastError = message
        }

        let playing = state == .playing
        let buffering = engine.isBuffering || state == .loading || state == .seeking
        let ended = state == .ended

        let positionMs = Int64(engine.currentTime * 1000)
        let durationMs = Int64(engine.duration * 1000)

        // Buffered position: furthest loaded time across AVPlayer's ranges.
        let bufferedMs: Int64 = {
            guard let player = findPlayerLayer()?.player,
                  let ranges = player.currentItem?.loadedTimeRanges,
                  let last = ranges.last?.timeRangeValue,
                  last.end.isValid else { return 0 }
            return Int64(CMTimeGetSeconds(last.end) * 1000)
        }()

        let videoCodec = Self.displayVideoCodec(base: videoCodecName, isDV: isDolbyVision, profile: dvProfile)
        let colorTransfer = Self.colorTransfer(for: engine.videoFormat)

        let audioTracks = audioTrackMaps()
        let activeAudio = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex })
        let selectedAudio = engine.activeAudioTrackIndex ?? audioTracks.first(where: { ($0["selected"] as? Bool) == true })?["index"] as? Int ?? -1

        let subtitleTracks = subtitleTrackMaps()
        let selectedSubtitle = engine.activeSubtitleTrackIndex ?? -1
        let activeSub = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex })
        let subtitleOn = engine.isSubtitleActive || selectedSubtitle >= 0
        let subtitleFormat = activeSub.map { Self.subtitleFormatLabel($0.codec) } ?? ""

        let map: [String: Any] = [
            "state": st,
            "playing": playing,
            "buffering": buffering,
            "ended": ended,
            "positionMs": positionMs,
            "durationMs": durationMs,
            "bufferedMs": bufferedMs,
            "videoCodecs": videoCodec,
            "videoMime": "",
            "videoWidth": videoWidth,
            "videoHeight": videoHeight,
            "colorTransfer": colorTransfer as Any,
            "audioCodecs": activeAudio?.codec ?? "",
            "audioMime": "",
            "audioChannels": activeAudio?.channels ?? 0,
            "audioTracks": audioTracks,
            "selectedAudioTrack": selectedAudio,
            "subtitleLabel": activeSub?.name ?? "",
            "subtitleFormat": subtitleFormat,
            "subtitleOn": subtitleOn,
            "subtitleTracks": subtitleTracks,
            "selectedSubtitleTrack": selectedSubtitle,
            "error": lastError ?? "",
        ]
        return map
    }

    private func emit() {
        guard let sink = eventSink else { return }
        sink(stateMap())
    }

    private func audioTrackMaps() -> [[String: Any]] {
        guard let engine else { return [] }
        let active = engine.activeAudioTrackIndex
        return engine.audioTracks.map { t in
            var m: [String: Any] = [
                "index": t.id,
                "codecs": t.codec,
                "mime": "",
                "channels": t.channels,
                "bitrate": Int(t.bitrate),
                "selected": t.id == active,
            ]
            if let language = t.language, !language.isEmpty { m["language"] = language }
            if !t.name.isEmpty { m["label"] = t.name }
            return m
        }
    }

    private func subtitleTrackMaps() -> [[String: Any]] {
        guard let engine else { return [] }
        let active = engine.activeSubtitleTrackIndex
        return engine.subtitleTracks.map { t in
            var m: [String: Any] = [
                "index": t.id,
                "codecs": Self.subtitleMime(t.codec),
                "mime": "",
                "sideloaded": t.isExternal,
                "selected": t.id == active,
            ]
            if let language = t.language, !language.isEmpty { m["language"] = language }
            if !t.name.isEmpty { m["label"] = t.name }
            return m
        }
    }

    // MARK: - Subtitle overlay

    private func updateSubtitleOverlay() {
        guard let engine else { return }
        subtitleOverlay.videoSize = CGSize(width: CGFloat(videoWidth), height: CGFloat(videoHeight))
        let t = engine.sourceTime
        guard let cue = engine.subtitleCues.first(where: { $0.startTime <= t && t < $0.endTime }) else {
            subtitleOverlay.clear()
            return
        }
        switch cue.body {
        case .text(let s):
            subtitleOverlay.show(text: s)
        case .richText(let runs):
            subtitleOverlay.show(text: runs.map(\.text).joined())
        case .image(let image):
            subtitleOverlay.show(image: image)
        }
    }

    // MARK: - Format helpers

    /// The Dart side detects Dolby Vision from a `dv*` codec prefix; synthesize
    /// a profile-qualified one, otherwise pass the libavcodec name through.
    private static func displayVideoCodec(base: String?, isDV: Bool, profile: Int?) -> String {
        if isDV {
            let p = profile ?? 8
            return String(format: "dvhe.%02d.06", p)
        }
        return base ?? ""
    }

    /// Media3 colorTransfer ints the Dart HDR detector understands (6 = PQ/HDR10, 7 = HLG).
    private static func colorTransfer(for format: VideoFormat) -> Int? {
        switch format {
        case .hdr10, .hdr10Plus, .dolbyVision: return 6
        case .hlg: return 7
        case .sdr: return nil
        }
    }

    /// Maps a libavcodec subtitle codec to the MIME the Dart `formatSubtitle` map knows.
    private static func subtitleMime(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip": return "application/x-subrip"
        case "ass", "ssa": return "text/x-ssa"
        case "webvtt": return "text/vtt"
        case "mov_text": return "application/x-quicktime-tx3g"
        case "pgssub", "hdmv_pgs_subtitle": return "application/pgs"
        case "dvb_subtitle": return "application/dvb"
        default: return codec
        }
    }

    private static func subtitleFormatLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip": return "SRT"
        case "ass", "ssa": return "SSA/ASS"
        case "webvtt": return "WebVTT"
        case "mov_text": return "TX3G"
        case "pgssub", "hdmv_pgs_subtitle": return "PGS"
        case "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }

    private static func url(for s: String) -> URL? {
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        return URL(string: s)
    }

    /// `dreamplayersmb://<token>.<ext>` -> (token, ext). nil when the URI is not
    /// an SMB stream URL. Token/ext parsed by string so URL quirks (empty path)
    /// can't break resolution; the extension is forwarded to AetherEngine as a
    /// `formatHint` so FFmpeg skips its byte-level format probe.
    private static func smbToken(in uri: String) -> (token: String, ext: String)? {
        let prefix = "dreamplayersmb://"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = String(uri.dropFirst(prefix.count))
        guard !rest.isEmpty else { return nil }
        let token = (rest as NSString).deletingPathExtension
        let ext = (rest as NSString).pathExtension
        guard !token.isEmpty else { return nil }
        return (token, ext)
    }

    // MARK: - Sidecar subtitle auto-pairing

    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "webvtt"]

    /// Attaches every sibling subtitle file in the video's folder (best
    /// filename-prefix match first, carrying the default selection), mirroring
    /// the Android side's auto-pairing.
    private static func siblingSubtitles(for videoURL: URL) -> [ExternalSubtitleTrack] {
        let videoBase = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: videoURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ) else { return [] }

        var scored: [(score: Int, url: URL)] = []
        for f in files {
            let ext = f.pathExtension.lowercased()
            guard subtitleExtensions.contains(ext) else { continue }
            let base = f.deletingPathExtension().lastPathComponent.lowercased()
            guard base.hasPrefix(videoBase) || videoBase.hasPrefix(base) else { continue }
            var score = base == videoBase ? 200 : 100
            score += min(base.count, videoBase.count)
            scored.append((score, f))
        }
        scored.sort { $0.score > $1.score }

        return scored.prefix(12).enumerated().map { i, item in
            let f = item.url
            let base = f.deletingPathExtension().lastPathComponent
            return ExternalSubtitleTrack(
                url: f,
                name: base,
                language: languageTag(in: base),
                isForced: false,
                isHearingImpaired: false,
                isDefault: i == 0,
                formatHint: f.pathExtension.lowercased()
            )
        }
    }

    /// Read the first 16 bytes from an SMB connection and guess the container
    /// format from magic bytes, so FFmpeg can skip its (failing) byte-level
    /// probe for extensionless files on the NAS.
    private static func sniffFormatFromSMB(_ conn: ByteRangeSource) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            guard let data = try? await conn.read(at: 0, length: 16), data.count >= 4 else {
                return
            }
            let bytes = [UInt8](data)
            // ftyp .... = MP4 / MOV / M4A
            if bytes.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 &&
               bytes[6] == 0x79 && bytes[7] == 0x70 { result = "mp4"; return }
            // EBML = Matroska / WebM
            if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
                result = "mkv"; return
            }
            // RIFF .... AVI = AVI
            if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
               bytes.count >= 12 && bytes[8] == 0x41 && bytes[9] == 0x56 &&
               bytes[10] == 0x49 && bytes[11] == 0x20 { result = "avi"; return }
            // 0x47 = MPEG-TS sync byte
            if bytes[0] == 0x47 { result = "ts"; return }
            // FLV header: 'F' 'L' 'V'
            if bytes[0] == 0x46 && bytes[1] == 0x4C && bytes[2] == 0x56 { result = "flv"; return }
            // ID3 = MP3 with ID3 tag
            if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { result = "mp3"; return }
            // OggS = Ogg container
            if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
                result = "ogg"; return
            }
            // \x00\x00\x01 = MPEG-PS / MPEG-TS pack start
            if bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x01 { result = "mpeg"; return }
        }
        semaphore.wait()
        return result
    }

    /// "House.S02E04.eng" -> "eng"; nil when the final dot-token is not a language code.
    private static func languageTag(in baseName: String) -> String? {
        guard let last = baseName.split(separator: ".").last else { return nil }
        let s = last.lowercased()
        if (s.count == 2 || s.count == 3) && s.allSatisfy({ $0.isLetter }) {
            return s
        }
        return nil
    }

    // MARK: - Teardown

    private func teardownAll() {
        stopTickTimer()
        cancellables.removeAll()
        engine?.stop()
        engine?.unbind(view: container)
        methodChannel.setMethodCallHandler(nil)
        eventChannel.setStreamHandler(nil)
        eventSink = nil
        UIApplication.shared.isIdleTimerDisabled = false
        for conn in previousStaleSMBConnections { conn.close() }
        previousStaleSMBConnections.removeAll()
    }
}
