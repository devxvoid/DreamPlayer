import AVFoundation
import AetherEngine
import AetherEngineSMB
import Combine
import Flutter
import UIKit

/// Subtitle overlay drawn by the host (AetherEngine decodes cues into
/// `engine.$subtitleCues`; the engine's `AetherPlayerView` does not paint them).
/// Text cues render in a label near the bottom; bitmap cues (PGS / DVB) render
/// in an image view positioned against the aspect-fit video rect.
private final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    private let imageView = UIImageView()

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
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        imageView.isHidden = true
        imageView.contentMode = .scaleToFill
        addSubview(imageView)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(text: String) {
        label.text = text
        label.isHidden = text.isEmpty
        imageView.isHidden = true
    }

    func show(image: SubtitleImage, videoRect: CGRect) {
        imageView.image = UIImage(cgImage: image.cgImage)
        imageView.isHidden = false
        label.isHidden = true
        let p = image.position
        imageView.frame = CGRect(
            x: videoRect.minX + p.minX * videoRect.width,
            y: videoRect.minY + p.minY * videoRect.height,
            width: p.width * videoRect.width,
            height: p.height * videoRect.height
        )
    }

    func clear() {
        label.isHidden = true
        imageView.isHidden = true
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

        // SMB streams arrive as `dreamplayersmb://<token>.<ext>` (see
        // SMBClient.openShare): resolve the token to the live SMBConnection
        // and load it as a custom IOReader source. AetherEngine's FFmpeg has no
        // network stack, so a loopback HTTP bridge is the wrong shape — this is
        // the engine's native SMB path (AetherEngineSMB).
        var source: MediaSource?
        var localURL: URL?
        smbToken = nil
        isSMBStream = false
        if let path, !path.isEmpty {
            localURL = URL(fileURLWithPath: path)
            source = .url(localURL!)
        } else if let uri, let parsed = Self.smbToken(in: uri) {
            guard let connection = SMBClient.shared.connection(for: parsed.token) else {
                result(FlutterError(code: "smb_stream", message: "SMB stream token not found", details: nil))
                return
            }
            // Read-ahead wrapper: SMBIOReader bridges every FFmpeg read to a
            // synchronous SMB round-trip (256 KB per read, zero prefetch), so
            // a Wi-Fi latency spike starves the engine's loopback producer and
            // AVPlayer buffers. BufferedSMBReader keeps a 32 MiB window filled
            // ahead of the cursor on a background task. ownsSource stays false
            // on both the connection and the reader — SMBClient owns the
            // connection's lifetime (closed on closeShare / server delete).
            smbToken = parsed.token
            isSMBStream = true
            source = .custom(
                BufferedSMBReader(source: connection),
                formatHint: nil
            )
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
                let probe = try await engine.load(source: source!, startPosition: startPosition, options: options)
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
        // The reconnect does a blocking SMB handshake (runAsync semaphore);
        // keep it off the main actor regardless of threading semantics.
        let pair = await Task.detached(priority: .userInitiated) {
            SMBClient.shared.reconnect(for: smbToken)
        }.value
        guard let pair else {
            lastError = "SMB stream reconnect failed for audio track switch"
            emit()
            return
        }
        let connection = pair.fresh
        let stale = pair.stale
        let source: MediaSource = .custom(
            BufferedSMBReader(source: connection),
            formatHint: nil
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
            // The engine has now swapped the stale reader/connection out; safe
            // to release the displaced connection.
            stale?.close()
            emit()
        } catch {
            lastError = String(describing: error)
            emit()
        }
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

    private func emit() {
        guard let sink = eventSink, let engine else { return }
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
        sink(map)
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
            subtitleOverlay.show(image: image, videoRect: videoRect(in: subtitleOverlay.bounds))
        }
    }

    private func videoRect(in bounds: CGRect) -> CGRect {
        guard videoWidth > 0, videoHeight > 0 else { return bounds }
        let aspect = CGFloat(videoWidth) / CGFloat(videoHeight)
        let viewAspect = bounds.width / max(bounds.height, 1)
        if viewAspect > aspect {
            let h = bounds.width / aspect
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        } else {
            let w = bounds.height * aspect
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
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
    /// can't break resolution; the extension is informational only (the custom
    /// source is probed, not format-hinted).
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
    }
}
