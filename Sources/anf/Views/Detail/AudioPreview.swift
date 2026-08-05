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
    /// Locked-popup hand-off (#103 follow-up): when set, 연속 재생 and the
    /// prev/next buttons call this with (current, ±1) instead of moving the
    /// pane's selection — the popup steps within its own snapshot queue and
    /// the browser stays untouched.
    var stepOverride: ((FileItem, Int) -> Void)? = nil
    /// Popup viewer only (#103: "뷰어로 열었을때 자동 플레이"): start playback
    /// the moment the file appears. The docked inspector keeps this off — arrow-
    /// key browsing must not blast audio per keystroke.
    var autoplayOnOpen = false

    @State private var engine = AudioPreviewEngine()
    @State private var artwork: NSImage?
    @State private var lyrics: String?
    @State private var synced: [SyncedLyricLine]?

    /// Sticky preferences (app-wide, deliberately not per-file).
    @AppStorage("anf.audio.volume") private var volume = 0.8
    @AppStorage("anf.audio.continuous") private var continuous = false
    @AppStorage("anf.audio.repeatOne") private var repeatOne = false

    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma"]
    static func isAudio(_ item: FileItem) -> Bool { audioExts.contains(item.ext) }

    var body: some View {
        VStack(spacing: 0) {
            // Artwork fills the flexible area; with embedded lyrics (#103) the
            // art yields to a scrollable lyrics sheet below a smaller cover.
            if let lyrics {
                VStack(spacing: 0) {
                    if let artwork {
                        IconImage(image: artwork)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                            .frame(maxHeight: 140)
                            .padding(.top, 16)
                    }
                    if let synced {
                        SyncedLyricsView(lines: synced, position: engine.position) { t in
                            engine.seek(to: t)
                            if !engine.playing { engine.play() }
                        }
                    } else {
                        ScrollView {
                            Text(lyrics)
                                .font(.system(size: 12.5))
                                .lineSpacing(4)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(16)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
            }

            VStack(spacing: 10) {
                // Seek bar with elapsed/total.
                HStack(spacing: 8) {
                    Text(Self.clock(engine.position))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { engine.position },
                                          set: { engine.scrub(to: $0) }),
                           in: 0...max(engine.duration, 0.01),
                           onEditingChanged: { editing in
                               editing ? engine.beginScrub() : engine.endScrub()
                           })
                        .controlSize(.small)
                        .disabled(engine.duration <= 0)
                    Text(Self.clock(engine.duration))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    // Prev / next track (#103: "이전곡 |<, 다음곡 >| 도 선택
                    // 가능하게") — 잠금 팝업은 스냅샷 큐, 기본은 선택 이동.
                    Button { step(-1) } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(L("Previous track", "이전 곡"))

                    Button { engine.toggle() } label: {
                        Image(systemName: engine.playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(engine.playing ? L("Pause (Space plays via Quick Look)", "일시 정지")
                                         : L("Play", "재생"))

                    Button { step(1) } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(L("Next track", "다음 곡"))

                    // Volume — the report asked for it by name.
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(maxWidth: 90)

                    Spacer(minLength: 0)

                    // Repeat-one (#103: "현재 곡만 반복재생 옵션도 보이면").
                    Button { repeatOne.toggle() } label: {
                        Image(systemName: "repeat.1")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(repeatOne ? Color.accentColor : Color.primary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(L("Repeat this track", "현재 곡 반복"))

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
            engine.load(url: item.url, volume: volume, autoplay: autoplayOnOpen)
            lyrics = nil
            synced = nil
            // Metadata loads can outlive a quick track change (SwiftUI cancels
            // the task but resumed awaits still run) — never let a stale track
            // stamp its art/lyrics onto the current one.
            let art = await AudioArtwork.load(url: item.url)
            guard !Task.isCancelled else { return }
            artwork = art
            let text = await AudioLyrics.load(url: item.url)
            guard !Task.isCancelled else { return }
            lyrics = text
            synced = text.flatMap(AudioLyrics.parseSynced)
        }
        .onChange(of: volume) { _, v in engine.setVolume(v) }
        .onChange(of: engine.finished) { _, done in
            guard done else { return }
            // Repeat-one outranks 연속 재생: rewind and go again.
            if repeatOne { engine.seek(to: 0); engine.play(); return }
            guard continuous else { return }
            playNextInFolder()
        }
        .onDisappear { engine.stop() }
    }

    /// Step to the adjacent audio file (+1 다음 곡 / -1 이전 곡). Default mode
    /// hands the SELECTION to that file — the preview follows and autoplays;
    /// a locked popup steps inside its snapshot queue via `stepOverride`.
    private func step(_ direction: Int) {
        if let stepOverride { stepOverride(item, direction); return }
        let audios = model.items.filter { Self.isAudio($0) }
        guard let idx = audios.firstIndex(where: { $0.id == item.id }),
              audios.indices.contains(idx + direction) else { return }
        AudioPreviewEngine.autoplayNext = true
        model.select(audios[idx + direction])
    }

    private func playNextInFolder() { step(1) }

    private static func clock(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Timestamped lyrics: the line under the playhead is highlighted and kept
/// centered as the song plays; clicking a line seeks there (#103 follow-up,
/// Petrichor-style). Plain VStack, not Lazy — scrollTo on unrendered lazy rows
/// is unreliable, and embedded lyrics are at most a few hundred lines.
private struct SyncedLyricsView: View {
    let lines: [SyncedLyricLine]
    let position: Double
    let onSeek: (Double) -> Void

    /// Last line whose stamp has passed; slight lead so a line lights up as
    /// it's sung, not a beat after.
    private var current: Int? {
        var idx: Int?
        for (i, l) in lines.enumerated() {
            if l.time <= position + 0.2 { idx = i } else { break }
        }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i].text.isEmpty ? " " : lines[i].text)
                            .font(.system(size: 12.5, weight: i == current ? .bold : .regular))
                            .foregroundStyle(i == current ? Color.primary : Color.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(lines[i].time) }
                            .id(i)
                    }
                }
                .padding(16)
            }
            .onChange(of: current) { _, i in
                guard let i else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
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
    private var stallObserver: (any NSObjectProtocol)?
    /// Bumped by load(); async duration fetches compare against it so a slow
    /// track (FLAC headers can take a while) can't stamp its duration onto
    /// whatever track replaced it — that stale write pinned the seek bar when
    /// 연속 재생 crossed from mp3 into flac (#103 follow-up).
    private var loadGeneration = 0

    private(set) var playing = false
    private(set) var duration: Double = 0
    var position: Double = 0
    /// Flips true once when the track plays to its end (drives 연속 재생).
    private(set) var finished = false
    /// True while the user drags the seek bar. The periodic observer must not
    /// fight the thumb, and the actual seek fires ONCE on release — a zero-
    /// tolerance seek per drag tick desynced mp3 playback from the reported
    /// position, which dragged the slider AND the synced lyrics off the audio
    /// (#103 follow-up).
    private(set) var scrubbing = false

    /// One-shot: set right before a continuous-play selection hand-off so the
    /// NEXT AudioPreview starts playing immediately.
    static var autoplayNext = false

    func load(url: URL, volume: Double, autoplay: Bool) {
        stop()
        loadGeneration += 1
        let gen = loadGeneration
        finished = false
        position = 0
        duration = 0
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = Float(volume)
        // File playback must not sit waiting for "enough buffer" — under a
        // disk I/O storm (배치 ffmpeg 변환이 같은 볼륨을 두드릴 때, #103) the
        // wait never resolves and the music just stops.
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        // Duration arrives asynchronously; poll it off the status key cheaply.
        Task { @MainActor [weak self] in
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite {
                guard let self, self.loadGeneration == gen else { return }
                self.duration = d
            }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 10),
                                                 queue: .main) { [weak self, weak item] t in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.position = t.seconds
                // FLAC (#103 follow-up): the asset header's duration is an
                // ESTIMATE and can under-report the real stream — the slider
                // then pins at the end while audio keeps playing. The live
                // item refines its duration during playback; track it, and
                // never let the reported duration fall behind the position.
                if let d = item?.duration.seconds, d.isFinite, d > 0, abs(d - self.duration) > 0.5 {
                    self.duration = d
                }
                // Creep only once a real duration is known. With duration
                // still 0 (the async header read hasn't landed — the window
                // right after 연속 재생 advances a track) creeping would grow
                // the slider range tick-by-tick and pin the thumb at the end
                // (#103 follow-up screenshot).
                if self.duration > 0, self.position > self.duration { self.duration = self.position }
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
        // I/O-storm resilience (#103: 변환 스크립트 실행 중 ~5초 뒤 멈춤): if
        // the stream stalls anyway, kick playback back into motion instead of
        // silently staying paused while the UI still says "playing".
        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                self.player?.play()
            }
        }
        if autoplay || Self.autoplayNext {
            Self.autoplayNext = false
            play()
        }
    }

    /// Replay needs a rewind: at end-of-track AVPlayer sits on the last frame
    /// and play() alone does nothing (#103: "한곡 재생 끝나고 다시 재생버튼을
    /// 누르면 플레이 안 됩니다"). Pure so the condition is testable.
    nonisolated static func shouldRewindBeforePlay(finished: Bool, position: Double,
                                                   duration: Double) -> Bool {
        finished || (duration > 0 && position >= duration - 0.05)
    }

    func play() {
        if Self.shouldRewindBeforePlay(finished: finished, position: position, duration: duration) {
            seek(to: 0)
        }
        player?.play(); playing = true
    }
    func pause() { player?.pause(); playing = false }
    func toggle() { playing ? pause() : play() }

    func beginScrub() { scrubbing = true }

    /// Slider value change: inside a drag session only the DISPLAY moves; a
    /// stray set with no session (keyboard arrows) seeks immediately.
    func scrub(to seconds: Double) {
        if scrubbing { position = seconds } else { seek(to: seconds) }
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        seek(to: position)
    }

    func seek(to seconds: Double) {
        position = seconds
        finished = false
        let gen = loadGeneration
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // mp3 has no sample index — the decoder can land off the request.
            // Adopt the player's OWN position so the slider and the synced
            // lyrics track the audio, not the wish (#103 follow-up). The
            // generation guard keeps a late completion from stamping its time
            // onto the NEXT track after 연속 재생 swaps the player.
            Task { @MainActor [weak self] in
                guard let self, !self.scrubbing, self.loadGeneration == gen,
                      let t = self.player?.currentTime().seconds, t.isFinite else { return }
                self.position = t
            }
        }
    }

    func setVolume(_ v: Double) { player?.volume = Float(v) }

    func stop() {
        if let t = timeObserver, let p = player { p.removeTimeObserver(t) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        if let s = stallObserver { NotificationCenter.default.removeObserver(s) }
        timeObserver = nil; endObserver = nil; stallObserver = nil
        player?.pause()
        player = nil
        playing = false
    }
}

/// Embedded lyrics (#103 follow-up: "가사를 볼 수 있는 방법은 없을까요") — ID3's
/// USLT frame and iTunes ©lyr via AVAsset; FLAC keeps lyrics in VORBIS_COMMENT
/// fields (LYRICS / UNSYNCEDLYRICS), which AVAsset doesn't surface, so those
/// ride the same hand parser as the artwork.
enum AudioLyrics {
    static func load(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        if let meta = try? await asset.load(.metadata) {
            let ids: [AVMetadataIdentifier] = [.id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics]
            for id in ids {
                let items = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id)
                if let loaded = try? await items.first?.load(.stringValue),
                   !loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return loaded
                }
            }
        }
        if url.pathExtension.lowercased() == "flac" {
            return await Task.detached(priority: .userInitiated) { flacLyrics(url: url) }.value
        }
        return nil
    }

    /// VORBIS_COMMENT (FLAC block type 4): vendor + field list, each
    /// "NAME=value" UTF-8. NOTE: lengths here are LITTLE-endian u32 — the one
    /// part of FLAC that isn't big-endian.
    static func flacLyrics(url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        func read(_ n: Int) -> Data? {
            guard n >= 0, let d = try? fh.read(upToCount: n), d.count == n else { return nil }
            return d
        }
        func be32(_ d: Data) -> Int { d.reduce(0) { ($0 << 8) | Int($1) } }
        func le32(_ d: Data) -> Int { d.reversed().reduce(0) { ($0 << 8) | Int($1) } }
        guard read(4) == Data("fLaC".utf8) else { return nil }
        while true {
            guard let head = read(4) else { return nil }
            let isLast = head[head.startIndex] & 0x80 != 0
            let type = head[head.startIndex] & 0x7F
            let size = be32(head.dropFirst())
            if type == 4, let block = read(size) {
                var o = block.startIndex
                func take(_ n: Int) -> Data? {
                    guard n >= 0, o + n <= block.endIndex else { return nil }
                    defer { o += n }
                    return block[o..<o + n]
                }
                guard let vendorLen = take(4).map(le32), take(vendorLen) != nil,
                      let count = take(4).map(le32) else { return nil }
                for _ in 0..<min(count, 256) {
                    guard let len = take(4).map(le32), let field = take(len),
                          let s = String(data: field, encoding: .utf8) else { return nil }
                    let upper = s.uppercased()
                    for key in ["LYRICS=", "UNSYNCEDLYRICS="] where upper.hasPrefix(key) {
                        let text = String(s.dropFirst(key.count))
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                    }
                }
                return nil
            }
            if isLast { return nil }
            guard size >= 0, (try? fh.seek(toOffset: fh.offsetInFile + UInt64(size))) != nil else { return nil }
        }
    }
}

/// One line of timestamped (LRC-style) lyrics.
struct SyncedLyricLine: Equatable, Sendable {
    let time: Double
    let text: String
}

extension AudioLyrics {
    /// LRC parse of embedded lyrics (#103 follow-up: highlight the current
    /// line as the song plays, Petrichor-style). Stamps look like [mm:ss.xx];
    /// one line may carry several (repeated chorus), [offset:±ms] shifts them
    /// all. Returns nil unless enough lines are stamped to trust the text as
    /// synced — some taggers leave a single stray stamp in plain lyrics.
    static func parseSynced(_ raw: String) -> [SyncedLyricLine]? {
        var offsetMS = 0.0
        var out: [SyncedLyricLine] = []
        for rawLine in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = rawLine
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = parseStamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let v = Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) {
                    offsetMS = v
                } else if times.isEmpty, tag.contains(":") {
                    // metadata tag ([ti:…], [ar:…], …) — drop it
                } else {
                    break   // a '[' that isn't a tag belongs to the lyric text
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { out.append(SyncedLyricLine(time: t, text: text)) }
        }
        guard out.count >= 4 else { return nil }
        let shift = offsetMS / 1000
        return out.map { SyncedLyricLine(time: max(0, $0.time - shift), text: $0.text) }
                  .sorted { $0.time < $1.time }
    }

    /// "mm:ss", "mm:ss.xx", "hh:mm:ss" → seconds; nil for anything else.
    private static func parseStamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var values: [Double] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isNumber || $0 == "." }), let v = Double(p) else { return nil }
            values.append(v)
        }
        let secs = values[values.count - 1]
        let mins = values[values.count - 2]
        let hours = values.count == 3 ? values[0] : 0
        return hours * 3600 + mins * 60 + secs
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
