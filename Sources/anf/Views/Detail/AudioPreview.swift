import SwiftUI
import AVFoundation

/// Native audio player for the inspector (#103). The Quick Look audio surface
/// hosts its controls in a remote layer whose hit-testing proved flaky inside
/// the inspector (clicks on play/stop went dead), offered no volume control,
/// and showed no artwork for FLAC. Owning the player fixes all three and adds
/// the asked-for continuous playback: when a track ends (with 연속 재생 on),
/// the selection advances to the folder's next audio file — the inspector
/// follows the selection, so the next track loads and plays by itself.
struct AudioPreview: View {
    let item: FileItem
    let model: BrowserModel

    @State private var engine = AudioPreviewEngine()
    @State private var artwork: NSImage?

    /// Sticky preferences (app-wide, deliberately not per-file).
    @AppStorage("anf.audio.volume") private var volume = 0.8
    @AppStorage("anf.audio.continuous") private var continuous = false

    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma"]
    static func isAudio(_ item: FileItem) -> Bool { audioExts.contains(item.ext) }

    var body: some View {
        VStack(spacing: 0) {
            // Artwork (or a big glyph) fills the flexible area, like QL did.
            ZStack {
                if let artwork {
                    IconImage(image: artwork)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                        .padding(24)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                // Seek bar with elapsed/total.
                HStack(spacing: 8) {
                    Text(Self.clock(engine.position))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { engine.position },
                                          set: { engine.seek(to: $0) }),
                           in: 0...max(engine.duration, 0.01))
                        .controlSize(.small)
                        .disabled(engine.duration <= 0)
                    Text(Self.clock(engine.duration))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    Button { engine.toggle() } label: {
                        Image(systemName: engine.playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(engine.playing ? L("Pause (Space plays via Quick Look)", "일시 정지")
                                         : L("Play", "재생"))

                    // Volume — the report asked for it by name.
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(maxWidth: 90)

                    Spacer(minLength: 0)

                    Toggle(isOn: $continuous) {
                        Text(L("Play all", "연속 재생")).font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    .help(L("Keep playing through the folder's audio files",
                            "폴더의 다음 오디오 파일을 이어서 재생"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .task(id: item.url) {
            engine.load(url: item.url, volume: volume, autoplay: false)
            artwork = await AudioArtwork.load(url: item.url)
        }
        .onChange(of: volume) { _, v in engine.setVolume(v) }
        .onChange(of: engine.finished) { _, done in
            guard done, continuous else { return }
            playNextInFolder()
        }
        .onDisappear { engine.stop() }
    }

    /// Continuous playback: hand the selection to the next audio file in listing
    /// order — the inspector tracks the selection, so the new file's preview
    /// mounts and starts playing (autoplay flag set by the engine hand-off).
    private func playNextInFolder() {
        let audios = model.items.filter { Self.isAudio($0) }
        guard let idx = audios.firstIndex(where: { $0.id == item.id }),
              idx + 1 < audios.count else { return }
        AudioPreviewEngine.autoplayNext = true
        model.select(audios[idx + 1])
    }

    private static func clock(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// AVPlayer wrapper with observable position/duration. @Observable so the
/// SwiftUI controls above track it without Combine plumbing.
@MainActor
@Observable
final class AudioPreviewEngine {
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?

    private(set) var playing = false
    private(set) var duration: Double = 0
    var position: Double = 0
    /// Flips true once when the track plays to its end (drives 연속 재생).
    private(set) var finished = false

    /// One-shot: set right before a continuous-play selection hand-off so the
    /// NEXT AudioPreview starts playing immediately.
    static var autoplayNext = false

    func load(url: URL, volume: Double, autoplay: Bool) {
        stop()
        finished = false
        position = 0
        duration = 0
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = Float(volume)
        player = p
        // Duration arrives asynchronously; poll it off the status key cheaply.
        Task { @MainActor [weak self] in
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite {
                self?.duration = d
            }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 10),
                                                 queue: .main) { [weak self, weak item] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds
                // FLAC (#103 follow-up): the asset header's duration is an
                // ESTIMATE and can under-report the real stream — the slider
                // then pins at the end while audio keeps playing. The live
                // item refines its duration during playback; track it, and
                // never let the reported duration fall behind the position.
                if let d = item?.duration.seconds, d.isFinite, d > 0, abs(d - self.duration) > 0.5 {
                    self.duration = d
                }
                if self.position > self.duration { self.duration = self.position }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playing = false
                self?.finished = true
            }
        }
        if autoplay || Self.autoplayNext {
            Self.autoplayNext = false
            play()
        }
    }

    func play() { player?.play(); playing = true }
    func pause() { player?.pause(); playing = false }
    func toggle() { playing ? pause() : play() }

    func seek(to seconds: Double) {
        position = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        finished = false
    }

    func setVolume(_ v: Double) { player?.volume = Float(v) }

    func stop() {
        if let t = timeObserver, let p = player { p.removeTimeObserver(t) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil; endObserver = nil
        player?.pause()
        player = nil
        playing = false
    }
}

/// Embedded artwork, including FLAC (#103: mp3 art showed, flac didn't — the
/// Quick Look surface only surfaced ID3 art). AVAsset's common metadata covers
/// ID3/iTunes/MP4; FLAC METADATA_BLOCK_PICTURE needs a hand parse.
enum AudioArtwork {
    static func load(url: URL) async -> NSImage? {
        // 1) AVAsset metadata (mp3/m4a and most others).
        let asset = AVURLAsset(url: url)
        if let meta = try? await asset.load(.metadata) {
            let artworkItems = AVMetadataItem.metadataItems(from: meta,
                                                            filteredByIdentifier: .commonIdentifierArtwork)
            if let data = try? await artworkItems.first?.load(.dataValue),
               let img = NSImage(data: data) {
                return img
            }
        }
        // 2) FLAC: parse the PICTURE metadata block directly.
        if url.pathExtension.lowercased() == "flac" {
            return await Task.detached(priority: .userInitiated) {
                flacPicture(url: url).flatMap(NSImage.init(data:))
            }.value
        }
        return nil
    }

    /// Minimal FLAC metadata walk: "fLaC" magic, then length-prefixed blocks;
    /// type 6 is PICTURE, whose payload embeds a length-prefixed MIME string,
    /// description, geometry, then the raw image bytes. Reads at most the
    /// metadata region (music data is never touched).
    static func flacPicture(url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        func read(_ n: Int) -> Data? {
            guard n >= 0, let d = try? fh.read(upToCount: n), d.count == n else { return nil }
            return d
        }
        func be32(_ d: Data) -> Int { d.reduce(0) { ($0 << 8) | Int($1) } }
        guard read(4) == Data("fLaC".utf8) else { return nil }
        while true {
            guard let head = read(4) else { return nil }
            let isLast = head[head.startIndex] & 0x80 != 0
            let type = head[head.startIndex] & 0x7F
            let size = be32(head.dropFirst())
            if type == 6, let block = read(size) {
                var o = block.startIndex + 4                       // skip picture type
                func take(_ n: Int) -> Data? {
                    guard o + n <= block.endIndex else { return nil }
                    defer { o += n }
                    return block[o..<o + n]
                }
                guard let mimeLen = take(4).map(be32), take(mimeLen) != nil,
                      let descLen = take(4).map(be32), take(descLen) != nil,
                      take(16) != nil,                             // w/h/depth/colors
                      let dataLen = take(4).map(be32),
                      let img = take(dataLen) else { return nil }
                return Data(img)
            }
            if isLast { return nil }
            guard size >= 0, (try? fh.seek(toOffset: fh.offsetInFile + UInt64(size))) != nil else { return nil }
        }
    }
}
