import Foundation

/// Watches Apple's chat.db write-ahead log and fires when Messages commits,
/// so live updates arrive near-instantly instead of on a fixed poll timer.
///
/// SQLite in WAL mode appends each commit to `<db>-wal` and periodically
/// checkpoints, which truncates or recreates that file. We watch the WAL file
/// descriptor for writes and re-arm when a checkpoint deletes it. Before the
/// WAL exists we watch the containing directory instead, so the very first
/// write (which creates the WAL) still wakes us.
final class ChatDatabaseWatcher: @unchecked Sendable {
    private let databaseURL: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.nebelhaus.trill.chatdb-watch")
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath = ""

    init(databaseURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.databaseURL = databaseURL
        self.onChange = onChange
    }

    func start() { queue.async { [weak self] in self?.arm() } }

    func stop() { queue.async { [weak self] in self?.disarm() } }

    private var walPath: String { databaseURL.path + "-wal" }
    private var directoryPath: String { databaseURL.deletingLastPathComponent().path }

    private func arm() {
        disarm()
        // Prefer the WAL — it changes on every commit. Fall back to the parent
        // directory so we still notice the WAL being created on the first write.
        let path = FileManager.default.fileExists(atPath: walPath) ? walPath : directoryPath
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // The Messages directory should always exist; retry shortly if not.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.onChange()
            // A checkpoint can delete or rename the WAL (invalidating this fd),
            // and once the WAL first appears we want to switch off the directory
            // watch onto it. Either way, re-arm.
            let walAppeared = self.watchedPath == self.directoryPath
                && FileManager.default.fileExists(atPath: self.walPath)
            if flags.contains(.delete) || flags.contains(.rename) || walAppeared {
                self.arm()
            }
        }
        src.setCancelHandler { close(fd) }
        watchedPath = path
        source = src
        src.resume()
    }

    private func disarm() {
        source?.cancel()   // cancel handler closes the descriptor
        source = nil
        watchedPath = ""
    }
}
