import AVFoundation
import CoreMedia
import Flutter
import UIKit

/// UIView whose backing layer is an `AVPlayerLayer`, so the native video
/// renders on its own Core Animation layer (real HDR / Dolby Vision output
/// where the display supports it).
private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
        AvPlayerView(messenger: messenger, viewId: viewId)
    }
}

/// Native AVPlayer-backed platform view mirroring the Android ExoPlayer
/// contract: same channel names (`dreamplayer/exo_<id>`,
/// `dreamplayer/exo_events_<id>`), same method names, same event map keys, so
/// the Dart `ExoPlayerController` works unchanged on both platforms.
///
/// AVPlayer supports embedded audio/subtitle track selection via
/// `AVMediaSelectionGroup` (audible/legible). Sideloaded sidecar subtitle
/// files are NOT attached here — AVPlayer has no sidecar-text API; that path
/// stays Android-only for now (embedded tracks work on iOS).
final class AvPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler {

    private let container: PlayerLayerView
    private let player: AVPlayer
    private var playerItem: AVPlayerItem?

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    private var timeObserver: Any?

    /// KVO tokens for the current item + the player (invalidated on teardown).
    private var observers: [NSKeyValueObservation] = []

    // ---- Track/format state, loaded asynchronously from the item's asset. ----
    private var videoCodecs: String?
    private var videoMime: String?
    private var colorTransfer: Int?
    private var audioTrackInfos: [AudioTrackInfo] = []
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var subtitleOn = false
    private var endedFlag = false
    private var lastError: String?

    private struct AudioTrackInfo {
        let codecs: String?
        let mime: String?
        let channels: Int
        let bitrate: Int
        let locale: Locale?
    }

    init(messenger: FlutterBinaryMessenger, viewId: Int64) {
        container = PlayerLayerView(frame: .zero)
        player = AVPlayer()
        methodChannel = FlutterMethodChannel(name: "dreamplayer/exo_\(viewId)", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "dreamplayer/exo_events_\(viewId)", binaryMessenger: messenger)
        super.init()

        container.backgroundColor = .black
        container.playerLayer.player = player
        container.playerLayer.videoGravity = .resizeAspect
        container.playerLayer.backgroundColor = UIColor.black.cgColor

        eventChannel.setStreamHandler(self)

        methodChannel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterMethodNotImplemented)
                return
            }
            let args = call.arguments as? [String: Any]
            switch call.method {
            case "open":
                self.open(args, result)
            case "play":
                self.player.play()
                result(nil)
            case "pause":
                self.player.pause()
                result(nil)
            case "seekTo":
                let ms = (args?["positionMs"] as? NSNumber)?.int64Value ?? 0
                self.seekTo(ms)
                result(nil)
            case "setVolume":
                let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 1
                self.player.volume = min(max(volume, 0), 1)
                result(nil)
            case "setMuted":
                self.player.isMuted = (args?["muted"] as? Bool) ?? false
                result(nil)
            case "getAudioTracks":
                result(self.buildAudioTracks().0)
            case "setAudioTrack":
                let index = (args?["index"] as? NSNumber)?.intValue ?? -1
                self.selectAudioTrack(index)
                result(nil)
            case "setSubtitles":
                let on = (args?["on"] as? Bool) ?? true
                self.setSubtitles(on)
                result(nil)
            case "getSubtitleTracks":
                result(self.buildSubtitleTracks().0)
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

    // MARK: - FlutterPlatformView

    func view() -> UIView { container }

    func dispose() {
        teardownAll()
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        addTimeObserver()
        emit()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        removeTimeObserver()
        return nil
    }

    // MARK: - Playback

    private func open(_ args: [String: Any]?, _ result: FlutterResult) {
        let path = args?["path"] as? String
        let uri = args?["uri"] as? String

        let url: URL
        if let path, !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else if let uri, let u = URL(string: uri) {
            url = u
        } else {
            result(FlutterError(code: "bad_args", message: "Missing path or uri", details: nil))
            return
        }

        // Play audio even with the mute switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        endedFlag = false
        lastError = nil
        videoCodecs = nil
        videoMime = nil
        colorTransfer = nil
        audioTrackInfos = []
        audibleGroup = nil
        legibleGroup = nil
        subtitleOn = false

        replace(with: AVPlayerItem(asset: asset))
        loadMetadata(for: asset)
        player.play()
        result(nil)
    }

    private func replace(with item: AVPlayerItem) {
        teardownItem()
        playerItem = item
        player.replaceCurrentItem(with: item)

        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.emit() }
        })
        observers.append(item.observe(\.status, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                if item.status == .failed {
                    self?.lastError = item.error?.localizedDescription
                }
                self?.emit()
            }
        })
        observers.append(item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.emit() }
        })

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(itemDidPlayToEnd(_:)),
                           name: .AVPlayerItemDidPlayToEndTime, object: item)
        center.addObserver(self, selector: #selector(itemStalled(_:)),
                           name: .AVPlayerItemPlaybackStalled, object: item)
        center.addObserver(self, selector: #selector(itemFailedToPlay(_:)),
                           name: .AVPlayerItemFailedToPlayToEndTime, object: item)
    }

    private func seekTo(_ ms: Int64) {
        endedFlag = false
        let target = CMTime(seconds: Double(ms) / 1000.0, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        emit()
    }

    private func loadMetadata(for asset: AVURLAsset) {
        asset.loadTracks(withMediaType: .video) { [weak self] tracks, _ in
            DispatchQueue.main.async {
                guard let self, let track = tracks?.first,
                      let desc = track.formatDescriptions.first as! CMFormatDescription? else { return }
                self.videoCodecs = Self.fourCC(desc)
                self.videoMime = "video/mp4"
                if let transfer = CMFormatDescriptionGetExtension(
                    desc,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction
                ) as? String {
                    self.colorTransfer = Self.colorTransferValue(transfer)
                }
                self.emit()
            }
        }

        asset.loadTracks(withMediaType: .audio) { [weak self] tracks, _ in
            var infos: [AudioTrackInfo] = []
            for track in tracks ?? [] {
                let desc = track.formatDescriptions.first as! CMFormatDescription?
                let codec = desc.map { Self.fourCC($0) }
                var channels = 0
                if let desc,
                   let audio = desc as? CMAudioFormatDescription,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audio) {
                    channels = Int(asbd.pointee.mChannelsPerFrame)
                }
                infos.append(AudioTrackInfo(
                    codecs: codec,
                    mime: codec.flatMap { Self.audioMime(forCodec: $0) },
                    channels: channels,
                    bitrate: Int(track.estimatedDataRate),
                    locale: track.locale
                ))
            }
            DispatchQueue.main.async {
                self?.audioTrackInfos = infos
                self?.emit()
            }
        }

        asset.loadMediaSelectionGroup(for: .audible) { [weak self] group, _ in
            DispatchQueue.main.async {
                self?.audibleGroup = group
                self?.emit()
            }
        }

        asset.loadMediaSelectionGroup(for: .legible) { [weak self] group, _ in
            DispatchQueue.main.async {
                self?.legibleGroup = group
                self?.emit()
            }
        }
    }

    // MARK: - Track selection

    private func buildAudioTracks() -> ([[String: Any]], Int) {
        guard let group = audibleGroup, let selection = player.currentItem?.currentMediaSelection else {
            if let info = audioTrackInfos.first {
                return ([trackMap(index: 0, language: nil, label: nil, info: info, selected: true)], 0)
            }
            return ([], -1)
        }
        let selectedOption = selection.selectedMediaOption(in: group)
        var tracks: [[String: Any]] = []
        var selected = -1
        for (i, option) in group.options.enumerated() {
            let info = audioInfo(for: option)
            let isSelected = selectedOption === option
            if isSelected { selected = i }
            tracks.append(trackMap(index: i, language: primaryLanguageCode(for: option),
                                   label: option.displayName, info: info, selected: isSelected))
        }
        return (tracks, selected)
    }

    private func trackMap(index: Int, language: String?, label: String?,
                          info: AudioTrackInfo?, selected: Bool) -> [String: Any] {
        var map: [String: Any] = [
            "index": index,
            "codecs": info?.codecs ?? "",
            "mime": info?.mime ?? "",
            "channels": info?.channels ?? 0,
            "bitrate": info?.bitrate ?? 0,
            "selected": selected,
        ]
        if let language { map["language"] = language }
        if let label { map["label"] = label }
        return map
    }

    private func audioInfo(for option: AVMediaSelectionOption) -> AudioTrackInfo? {
        if let locale = option.locale,
           let match = audioTrackInfos.first(where: { $0.locale == locale }) {
            return match
        }
        return audioTrackInfos.first
    }

    /// Primary ISO-639 code from the selection option's language tag, e.g.
    /// "en-US" -> "en", so the Dart language-name map can look it up.
    private func primaryLanguageCode(for option: AVMediaSelectionOption) -> String? {
        let tag = option.extendedLanguageTag ?? option.locale?.identifier
        return tag?.split(separator: "-").first.map(String.init)
    }

    private func selectedAudioInfo() -> AudioTrackInfo? {
        guard let group = audibleGroup,
              let selection = player.currentItem?.currentMediaSelection,
              let option = selection.selectedMediaOption(in: group) else {
            return audioTrackInfos.first
        }
        return audioInfo(for: option)
    }

    private func selectAudioTrack(_ index: Int) {
        guard let group = audibleGroup, let item = player.currentItem,
              index >= 0, index < group.options.count else { return }
        item.select(group.options[index], in: group)
        emit()
    }

    private func buildSubtitleTracks() -> ([[String: Any]], Int) {
        guard let group = legibleGroup, let selection = player.currentItem?.currentMediaSelection else {
            return ([], -1)
        }
        let selectedOption = selection.selectedMediaOption(in: group)
        var tracks: [[String: Any]] = []
        var selected = -1
        for (i, option) in group.options.enumerated() {
            let isSelected = selectedOption === option
            if isSelected { selected = i }
            tracks.append([
                "index": i,
                "language": primaryLanguageCode(for: option) ?? "",
                "label": option.displayName,
                "codecs": "",
                "mime": "",
                "sideloaded": false,
                "selected": isSelected,
            ])
        }
        return (tracks, selected)
    }

    private func setSubtitles(_ on: Bool) {
        guard let group = legibleGroup, let item = player.currentItem else { return }
        if on {
            if let current = item.currentMediaSelection.selectedMediaOption(in: group) {
                item.select(current, in: group)
            } else if let first = group.options.first {
                item.select(first, in: group)
            }
        } else {
            item.select(nil, in: group)
        }
        subtitleOn = on
        emit()
    }

    private func selectSubtitleTrack(_ index: Int) {
        guard let group = legibleGroup, let item = player.currentItem else { return }
        if index >= 0, index < group.options.count {
            item.select(group.options[index], in: group)
        } else {
            item.select(nil, in: group)
        }
        subtitleOn = index >= 0
        emit()
    }

    // MARK: - Event emission

    private func addTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.emit()
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func emit() {
        guard let sink = eventSink else { return }
        let item = player.currentItem
        let timeControl = player.timeControlStatus

        let buffering: Bool
        if item?.status != .readyToPlay {
            buffering = true
        } else {
            buffering = timeControl == .waitingToPlayAtSpecifiedRate
        }
        let playing = timeControl == .playing && player.rate > 0
        let ended = endedFlag

        let positionMs = finiteSeconds(player.currentTime().seconds) * 1000
        let durationSeconds = item?.duration.seconds ?? 0
        let durationMs = finiteSeconds(durationSeconds) * 1000

        let size = item?.presentationSize ?? .zero
        let videoWidth = size.width > 0 ? Int(size.width) : 0
        let videoHeight = size.height > 0 ? Int(size.height) : 0

        let audioInfo = selectedAudioInfo()
        let (audioTracks, selectedAudio) = buildAudioTracks()
        let (subtitleTracks, selectedSubtitle) = buildSubtitleTracks()
        subtitleOn = selectedSubtitle >= 0
        let subtitleLabel = subtitleOn && selectedSubtitle >= 0
            ? legibleGroup?.options[selectedSubtitle].displayName
            : nil

        let state = item == nil ? 1 : (ended ? 4 : (buffering ? 2 : 3))

        let map: [String: Any] = [
            "state": state,
            "playing": playing,
            "buffering": buffering,
            "ended": ended,
            "positionMs": Int64(positionMs),
            "durationMs": Int64(durationMs),
            "videoCodecs": videoCodecs ?? "",
            "videoMime": videoMime ?? "",
            "videoWidth": videoWidth,
            "videoHeight": videoHeight,
            "colorTransfer": colorTransfer as Any,
            "audioCodecs": audioInfo?.codecs ?? "",
            "audioMime": audioInfo?.mime ?? "",
            "audioChannels": audioInfo?.channels ?? 0,
            "audioTracks": audioTracks,
            "selectedAudioTrack": selectedAudio,
            "subtitleLabel": subtitleLabel ?? "",
            "subtitleFormat": "",
            "subtitleOn": subtitleOn,
            "subtitleTracks": subtitleTracks,
            "selectedSubtitleTrack": selectedSubtitle,
            "error": lastError ?? "",
        ]
        sink(map)
    }

    private func finiteSeconds(_ seconds: Double) -> Double {
        seconds.isFinite ? seconds : 0
    }

    // MARK: - Format helpers

    private static func fourCC(_ desc: CMFormatDescription) -> String {
        let cc = CMFormatDescriptionGetMediaSubType(desc)
        let bytes: [UInt8] = [
            UInt8((cc >> 24) & 0xFF),
            UInt8((cc >> 16) & 0xFF),
            UInt8((cc >> 8) & 0xFF),
            UInt8(cc & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func audioMime(forCodec codec: String) -> String? {
        switch codec {
        case "ac-3": return "audio/ac3"
        case "ec-3": return "audio/eac3"
        case "mp4a": return "audio/mp4a-latm"
        case "alac": return "audio/alac"
        case "flac": return "audio/flac"
        case "lpcm": return "audio/raw"
        default: return nil
        }
    }

    /// Maps the track's transfer function to the Media3 colorTransfer int the
    /// Dart HDR detector understands (6 = HDR10/PQ, 7 = HLG). Dolby Vision is
    /// detected from the codec (`dvhe`/`dvh1`/`dvav`) by the Dart side.
    private static func colorTransferValue(_ transfer: String) -> Int? {
        let t = transfer.uppercased()
        if t.contains("2084") || t.contains("PQ") { return 6 }
        if t.contains("B67") || t.contains("HLG") { return 7 }
        return nil
    }

    // MARK: - Notifications

    @objc private func itemDidPlayToEnd(_ note: Notification) {
        endedFlag = true
        emit()
    }

    @objc private func itemStalled(_ note: Notification) {
        emit()
    }

    @objc private func itemFailedToPlay(_ note: Notification) {
        lastError = "Playback failed"
        emit()
    }

    // MARK: - Teardown

    private func teardownItem() {
        observers.forEach { $0.invalidate() }
        observers.removeAll()
        if let playerItem {
            NotificationCenter.default.removeObserver(self, name: nil, object: playerItem)
        }
        playerItem = nil
    }

    private func teardownAll() {
        removeTimeObserver()
        teardownItem()
        methodChannel.setMethodCallHandler(nil)
        eventChannel.setStreamHandler(nil)
        eventSink = nil
        UIApplication.shared.isIdleTimerDisabled = false
        player.pause()
        container.playerLayer.player = nil
    }
}
