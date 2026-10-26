import AVFoundation
import AVKit
import SwiftUI

/// Plays every clip of a visit back to back. Clips stream from Arlo's signed links and are
/// never downloaded to the device.
struct ClipPlayerView: View {
    let visit: Visit
    let cameraName: String

    @State private var player: AVQueuePlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        ContentUnavailableView("This clip isn't available", systemImage: "film")
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: AG.tileRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(visit.category.title)
                        .font(.ag(22, .medium))
                    Text("\(cameraName) · \(visit.start.formatted(date: .abbreviated, time: .shortened))")
                        .font(.ag(14))
                        .foregroundStyle(AG.stone500)
                    if visit.clips.count > 1 {
                        Text("\(visit.clips.count) clips, played in order")
                            .font(.ag(13))
                            .foregroundStyle(AG.stone500)
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(AG.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let items = visit.clips
                .sorted { $0.createdAt < $1.createdAt }
                .compactMap(\.contentURL)
                .map { AVPlayerItem(asset: AVURLAsset(url: $0, options: [AVURLAssetHTTPUserAgentKey: Arlo.userAgent])) }
            guard !items.isEmpty else { return }
            let queue = AVQueuePlayer(items: items)
            player = queue
            queue.play()
        }
        .onDisappear {
            player?.pause()
            player?.removeAllItems()
            player = nil
        }
    }
}
