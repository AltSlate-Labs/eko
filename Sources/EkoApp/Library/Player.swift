import AVFoundation
import EkoCore
import SwiftUI

/// Plays one recording. Split recordings (You left, Others right) are mixed so both sides are heard in both ears.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var started = false
    /// The recording's loudness outline for the scrubber (empty while it is being read).
    @Published private(set) var levels: [Float] = []
    private static var levelCache: [String: [Float]] = [:]
    @Published var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// The recording in the player (nil when stopped).
    @Published private(set) var loaded: URL?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, t.seconds.isFinite else { return }
                self.time = t.seconds
            }
        }
    }

    func load(_ item: RecordingItem) async {
        guard loaded != item.url else { return }
        stop()
        loaded = item.url
        let asset = AVURLAsset(url: item.url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.audioTimePitchAlgorithm = .timeDomain   // speech stays natural at 1.5× and 2×
        if item.split, let track = try? await asset.loadTracks(withMediaType: .audio).first {
            playerItem.audioMix = MonoMix.audioMix(for: track)
        }
        var length = item.duration ?? 0
        if length <= 0, let d = try? await asset.load(.duration), d.isNumeric { length = d.seconds }
        guard loaded == item.url else { return }   // another recording was opened meanwhile
        duration = length
        loadLevels(item.url)
        player.replaceCurrentItem(with: playerItem)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.time = self?.duration ?? 0
            }
        }
    }

    private func loadLevels(_ url: URL) {
        if let cached = Self.levelCache[url.path] { levels = cached; return }
        levels = []
        Task {
            let outline = await Task.detached(priority: .utility) { (try? Waveform.envelope(of: url, bins: 180)) ?? [] }.value
            Self.levelCache[url.path] = outline
            if loaded == url { levels = outline }
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    /// For the list's row players, which share one Player: play or pause this recording, switching from
    /// whichever was playing; with `at` (0…1), start from that point.
    func toggle(_ item: RecordingItem, at fraction: Double? = nil) async {
        if loaded != item.url { await load(item) }
        guard loaded == item.url else { return }   // another row was clicked meanwhile
        if let fraction { seek(to: fraction * duration, play: true) } else { toggle() }
    }

    func play() {
        guard player.currentItem != nil else { return }
        if duration > 0, time >= duration - 0.3 { seek(to: 0, play: false) }
        player.playImmediately(atRate: rate)
        isPlaying = true
        started = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// The one entry point for every timestamp link in the transcript, summary and chat.
    func seek(to seconds: TimeInterval, play: Bool = true) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        time = target
        started = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play { self.play() }
    }

    func skip(_ delta: TimeInterval) { seek(to: time + delta, play: isPlaying) }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        loaded = nil
        isPlaying = false
        started = false
        time = 0
    }
}

/// The player card: a waveform you click or drag to move through the call, and quiet transport controls.
struct PlayerBar: View {
    @EnvironmentObject private var player: Player
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 10) {
            WaveformScrubber(levels: player.levels, progress: progress) { fraction, done in
                if done {
                    player.seek(to: fraction * player.duration, play: player.isPlaying || !player.started)
                    scrub = nil
                } else {
                    scrub = fraction * player.duration
                }
            }
            .frame(height: 46)

            HStack(spacing: 0) {
                Text(Timestamp.short(scrub ?? player.time))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(scrub == nil ? Theme.secondary : Theme.accent)
                    .frame(width: 70, alignment: .leading)
                Spacer()
                HStack(spacing: 22) {
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 15)) }
                        .help("Back 15 seconds")
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.accent))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help(player.isPlaying ? "Pause" : "Play")
                    Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 15)) }
                        .help("Forward 15 seconds")
                }
                .foregroundStyle(Theme.secondary)
                Spacer()
                HStack(spacing: 10) {
                    Menu {
                        Picker("Speed", selection: $player.rate) {
                            ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { Text(Self.speed($0)).tag($0) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: {
                        Text(Self.speed(player.rate)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().strokeBorder(Theme.hairline))
                    .help("Playback speed")
                    Text(Timestamp.short(player.duration))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                .frame(width: 70 + 40, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, (scrub ?? player.time) / player.duration)
    }

    static func speed(_ r: Float) -> String { r == 1 ? "1×" : String(format: "%g×", r) }
}

/// Bars of the recording's loudness; the played part in the accent. Click or drag to move.
struct WaveformScrubber: View {
    let levels: [Float]
    let progress: Double
    /// (position 0…1, finished dragging)
    let onScrub: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let count = levels.isEmpty ? 120 : levels.count
                let step = size.width / CGFloat(count)
                let bar = max(1.5, step * 0.55)
                for i in 0..<count {
                    let level = levels.isEmpty ? 0.06 : CGFloat(max(0.06, levels[i]))
                    let h = max(3, level * size.height)
                    let x = CGFloat(i) * step + (step - bar) / 2
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h)
                    let played = (CGFloat(i) + 0.5) / CGFloat(count) <= progress
                    context.fill(Path(roundedRect: rect, cornerRadius: bar / 2),
                                 with: .color(played ? Theme.accent : Theme.tertiary.opacity(levels.isEmpty ? 0.3 : 0.55)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onScrub(min(1, max(0, $0.location.x / geo.size.width)), false) }
                .onEnded { onScrub(min(1, max(0, $0.location.x / geo.size.width)), true) })
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
