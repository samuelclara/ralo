import SwiftUI
import UIKit

/// Loads snapshots and clip thumbnails into memory only. Nothing touches the disk cache,
/// and the memory cache is emptied whenever the app locks.
actor SecureImageLoader {
    static let shared = SecureImageLoader()

    private let session = URLSession(configuration: ArloTransport.hardenedConfiguration(),
                                     delegate: RedirectBlocker(), delegateQueue: nil)
    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 120
    }

    func image(for url: URL) async -> UIImage? {
        guard url.scheme == "https" else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return await task.value }

        let session = self.session
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.setValue(Arlo.userAgent, forHTTPHeaderField: "User-Agent")
            guard
                let result = try? await session.data(for: request),
                (result.1 as? HTTPURLResponse)?.statusCode == 200,
                let image = UIImage(data: result.0)
            else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        let purgesBefore = purges
        let image = await task.value
        // A purge while this was loading means the app locked: don't refill the cache.
        guard purges == purgesBefore else { return nil }
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    private var purges = 0

    func purge() {
        purges += 1
        cache.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }
}

/// A camera frame or clip thumbnail, loaded privately. Shows the dark placeholder until ready.
struct SecureImage: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            AG.ink800
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "video")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(AG.stone500)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            let loaded = await SecureImageLoader.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
