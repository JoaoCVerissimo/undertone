import AppKit
import Foundation

/// Fetches and caches thumbnails. Tiny on purpose: a handful of images, in memory only.
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 20
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
                  let image = NSImage(data: data)
            else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
