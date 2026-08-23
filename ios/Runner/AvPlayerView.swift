import AVFoundation
import AetherEngine
import AetherEngineSMB
import Combine
import Flutter
import MediaPlayer
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

    // MARK: - User subtitle appearance

    /// Applies the user's subtitle appearance from Dart (`setSubtitleStyle`).
    /// - `size` multiplies the base glyph size.
    /// - `color` is the text ARGB; `bg` an ARGB cue-box (alpha 0 = none).
    /// - `outline` toggles the black shadow behind glyphs.
    func applyStyle(size: Double, color: Int, bg: Int, outline: Bool) {
        let base = CGFloat(17 * size.clamped(0.6...2.0))
        label.font = .systemFont(ofSize: base, weight: .semibold)
        label.textColor = UIColor(argb: color)
        if (bg >> 24) != 0 {
            label.backgroundColor = UIColor(argb: bg)
            layer.cornerRadius = 4
            label.layer.cornerRadius = 4
            label.clipsToBounds = true
        } else {
            label.backgroundColor = nil
        }
        if outline {
            label.shadowColor = .black
            label.shadowOffset = CGSize(width: 1, height: 1)
        } else {
            label.shadowColor = nil
        }
        setNeedsLayout()
    }

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
    private var lastWebDAVInfo: (url: URL, headers: [String: String], allowSelfSigned: Bool)?

    /// Subtitle cue shift from the user's appearance settings (seconds).
    /// Positive = cues appear LATER than authored.
    private var subtitleDelaySeconds: Double = 0

    

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
                    self.engine?.selectAudioTrack(index: index)
                    // For custom IOReader sources (WebDAV), the engine may need
                    // to re-probe the container on track switch and hit
                    // "open failed" if the reader can't rewind.  If that
                    // happens the engine transitions to .error — detect it
                    // and do a full reload as a fallback.
                    if self.lastWebDAVInfo != nil {
                        // Give the engine a moment to process the switch.
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard let self, let engine else { return }
                            if case .error = engine.state {
                                let pos = engine.currentTime
                                await self.reloadSession(at: pos)
                                self.engine?.selectAudioTrack(index: index)
                                self.emit()
                            }
                        }
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
                case "setSubtitleStyle":
                    let size = (args?["size"] as? NSNumber)?.doubleValue ?? 1.0
                    let color = (args?["color"] as? NSNumber)?.intValue ?? 0xFFFFFFFF
                    let bg = (args?["bg"] as? NSNumber)?.intValue ?? 0x80000000
                    let outline = (args?["outline"] as? Bool) ?? true
                    self.subtitleDelaySeconds =
                        ((args?["delayMs"] as? NSNumber)?.doubleValue ?? 0) / 1000.0
                    self.subtitleOverlay.applyStyle(
                        size: size, color: color, bg: bg, outline: outline)
                    result(nil)
                case "setResizeMode":
                    let mode = (args?["mode"] as? NSNumber)?.intValue ?? 0
                    self.setResizeMode(mode)
                    result(nil)
                case "setBrightness":
                    let brightness = (args?["brightness"] as? NSNumber)?.floatValue ?? 0.5
                    UIScreen.main.brightness = CGFloat(max(0, min(brightness, 1)))
                    result(nil)
                case "getBrightness":
                    result(Float(UIScreen.main.brightness))
                case "getSystemVolume":
                    let vol = AVAudioSession.sharedInstance().outputVolume
                    result(Float(vol))
                case "setSystemVolume":
                    let volume = min(max(((args?["volume"] as? NSNumber)?.floatValue ?? 1), 0), 1)
                    self.setSystemVolume(volume)
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

        // Source pending construction: some sources need background I/O
        // (WebDAV size probe) before the engine can load.
        var source: MediaSource?
        var localURL: URL?
        var webDAVSource: (url: URL, headers: [String: String], allowSelfSigned: Bool)?
        if let path, !path.isEmpty {
            localURL = URL(fileURLWithPath: path)
            source = .url(localURL!)
        } else if let uri, let u = URL(string: uri),
                  (u.scheme?.lowercased() == "http" || u.scheme?.lowercased() == "https"),
                  !httpHeaders.isEmpty || allowSelfSigned {
            // WebDAV playback: auth headers AND self-signed HTTPS can't go
            // through AetherEngine's own HTTP stack (no headers API, and its
            // TLS validation can't be bypassed), so serve the stream as a
            // custom ByteRangeSource — each read is an independent HTTP Range
            // request carrying the Authorization header on the permissive or
            // default-trust session. Wrapped in BufferedSMBReader for read-ahead (the
            // loopback producer starves on per-read network round-trips). The
            // source is stateless per read, so the engine's internal reload on
            // audio-track switch is safe.
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
        lastWebDAVInfo = nil
        subtitleOverlay.clear()
        emit()

        // Sidecar subtitles: an explicit `subtitleUri` wins; then external
        // subtitles from the server (e.g. Jellyfin); then auto-pair sibling
        // files in the video's folder (best match first, like Android).
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
        // External subtitles from the server (e.g. Jellyfin DeliveryUrl).
        if let rawExternalSubs = args?["externalSubtitles"] as? [[String: Any]] {
            for entry in rawExternalSubs {
                guard let urlStr = entry["uri"] as? String,
                      !urlStr.isEmpty,
                      let url = URL(string: urlStr) else { continue }
                let label = entry["label"] as? String ?? "Track"
                let language = entry["language"] as? String ?? ""
                let isDefault = entry["isDefault"] as? Bool == true
                let mimeType = entry["mimeType"] as? String ?? "application/x-subrip"
                let formatHint = mimeType.contains("ssa") ? "ass"
                    : mimeType.contains("vtt") ? "vtt"
                    : mimeType.contains("ttml") ? "ttml"
                    : "srt"
                let track = ExternalSubtitleTrack(
                    url: url,
                    name: language.isEmpty ? label : "\(language) · \(label)",
                    language: language.isEmpty ? nil : language,
                    isForced: false,
                    isHearingImpaired: false,
                    isDefault: isDefault,
                    formatHint: formatHint,
                )
                externals.append(track)
                if isDefault && pendingAutoSubtitleIndex == nil {
                    pendingAutoSubtitleIndex = AetherEngine.externalSubtitleTrackIDBase + (externals.count - 1)
                }
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
                self.lastWebDAVInfo = webDAVSource
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
    /// For WebDAV custom sources the underlying IOReader is consumed and
    /// can't rewind, so we re-resolve a fresh source instead of reusing `lastSource`.
    private func reloadSession(at position: Double) async {
        guard let engine else { return }
        let activeSub = engine.activeSubtitleTrackIndex
        do {
            let freshSource = try await buildFreshSource()
            guard let freshSource else { return }
            lastSource = freshSource
            let probe = try await engine.load(source: freshSource, startPosition: position, options: lastLoadOptions)
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

    /// Builds a fresh `MediaSource` from the stored open info.
    /// WebDAV: new HTTP session → new BufferedSMBReader.
    /// Local file: reuses the file URL (always re-openable).
    private func buildFreshSource() async throws -> MediaSource? {
        if let web = lastWebDAVInfo {
            let byteSource = try await Task.detached(priority: .userInitiated) {
                try WebDAVClient.shared.makeByteRangeSource(
                    url: web.url,
                    headers: web.headers,
                    allowSelfSigned: web.allowSelfSigned
                )
            }.value
            let ext = web.url.pathExtension.lowercased()
            return .custom(
                BufferedSMBReader(source: byteSource),
                formatHint: ext.isEmpty ? nil : ext
            )
        }
        return lastSource  // local file: always re-openable
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
        // Apply the user's delay: positive = look for cues authored later.
        let t = engine.sourceTime - subtitleDelaySeconds
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

    /// "House.S02E04.eng" -> "eng"; nil when the final dot-token is not a language code.
    private static func languageTag(in baseName: String) -> String? {
        guard let last = baseName.split(separator: ".").last else { return nil }
        let s = last.lowercased()
        if (s.count == 2 || s.count == 3) && s.allSatisfy({ $0.isLetter }) {
            return s
        }
        return nil
    }

    // MARK: - System volume (MPVolumeView)

    /// MPVolumeView is the only public way to set the SYSTEM volume on iOS.
    /// Its internal UISlider is built asynchronously after the view lands in a
    /// window, so we retain the view for this player's lifetime and retry the
    /// lookup with a bounded backoff — the naive synchronous `subviews.first`
    /// search always returned nil, which made the volume gesture a no-op.
    private var mpVolumeView: MPVolumeView?
    private var mpVolumeRetries = 0

    private func setSystemVolume(_ value: Float) {
        DispatchQueue.main.async {
            if self.mpVolumeView == nil {
                let mpVolume = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                keyWindow?.addSubview(mpVolume)
                self.mpVolumeView = mpVolume
                self.mpVolumeRetries = 0
            }
            guard let mpVolume = self.mpVolumeView else { return }
            if let slider = Self.findVolumeSlider(in: mpVolume) {
                slider.value = value
            } else if self.mpVolumeRetries < 20 {
                // Slider not materialized yet — retry shortly.
                self.mpVolumeRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.setSystemVolume(value)
                }
            }
        }
    }

    private static func findVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let slider = findVolumeSlider(in: sub) { return slider }
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
        mpVolumeView?.removeFromSuperview()
        mpVolumeView = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

// MARK: - Style helpers

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension UIColor {
    /// ARGB int from the Dart side (alpha in the top byte).
    convenience init(argb: Int) {
        self.init(
            red: CGFloat((argb >> 16) & 0xFF) / 255.0,
            green: CGFloat((argb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(argb & 0xFF) / 255.0,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255.0
        )
    }
}
