import CryptoKit
import Foundation

/// App-owned, bounded cache for Beeper attachments.
///
/// Beeper's `srcURL` "may be temporary or local-only to this device", and the
/// local path `/v1/assets/download` reports lives inside **Beeper's** storage —
/// pointing a `MessageAttachment.localURL` at either would hand the UI a path
/// that can vanish or that we don't own. So bytes are streamed through
/// `/v1/assets/serve` into our own Caches directory, and only then does an
/// attachment stop being `.downloadRequired`.
///
/// Bounded on purpose: a per-file size cap and an allowed-type check, because
/// the bytes come off a network boundary.
actor BeeperAssetCache {
    /// Per-file ceiling. Larger attachments stay `.downloadRequired` and are
    /// simply not previewed; nothing is truncated.
    static let maximumFileBytes = 64 * 1024 * 1024

    private let directory: URL
    private var inFlight: [String: Task<URL?, Never>] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.nebelhaus.trill", isDirectory: true)
            .appendingPathComponent("BeeperAssets", isDirectory: true)
    }

    /// A local URL for `remoteID` (an `mxc://`/`localmxc://` handle), fetching it
    /// once if needed. Nil on any failure — an attachment we can't fetch stays
    /// `.downloadRequired`, which is exactly what that state means.
    ///
    /// Concurrent callers for the same asset share one download rather than
    /// racing to write the same file.
    func localURL(
        for remoteID: String,
        mimeType: String?,
        using client: BeeperClient
    ) async -> URL? {
        guard isAllowed(mimeType: mimeType) else { return nil }
        let destination = destinationURL(for: remoteID, mimeType: mimeType)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let existing = inFlight[remoteID] { return await existing.value }

        let task = Task<URL?, Never> { [directory] in
            do {
                let (data, contentType) = try await client.assetBytes(
                    url: remoteID,
                    maximumBytes: Self.maximumFileBytes
                )
                guard isAllowed(mimeType: mimeType ?? contentType) else { return nil }
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                // Write to a sibling then move, so a cancelled or failed write
                // can't leave a half file that later reads as cached.
                let staging = destination.appendingPathExtension("partial")
                try data.write(to: staging, options: .atomic)
                _ = try? FileManager.default.replaceItemAt(destination, withItemAt: staging)
                return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
            } catch {
                AppLog.repository.error(
                    "Beeper asset fetch failed error=\(String(describing: type(of: error)), privacy: .public)"
                )
                return nil
            }
        }
        inFlight[remoteID] = task
        let result = await task.value
        inFlight.removeValue(forKey: remoteID)
        return result
    }

    /// Only media we would actually render. An executable or archive arriving
    /// from a network boundary has no business in a preview cache.
    private nonisolated func isAllowed(mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        return mimeType.hasPrefix("image/")
            || mimeType.hasPrefix("video/")
            || mimeType.hasPrefix("audio/")
    }

    /// Content-addressed by the remote handle, so the same asset is fetched once
    /// and an untrusted `fileName` never reaches the filesystem.
    private nonisolated func destinationURL(for remoteID: String, mimeType: String?) -> URL {
        let digest = SHA256.hash(data: Data(remoteID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = fileExtension(for: mimeType)
        return directory.appendingPathComponent(ext.isEmpty ? digest : "\(digest).\(ext)")
    }

    private nonisolated func fileExtension(for mimeType: String?) -> String {
        switch mimeType?.split(separator: ";").first.map(String.init)?.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/heic": "heic"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "audio/mpeg": "mp3"
        case "audio/mp4", "audio/aac": "m4a"
        case "audio/ogg": "ogg"
        default: ""
        }
    }
}
