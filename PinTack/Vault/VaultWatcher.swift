import Foundation
import CoreServices

/// FSEvents stream over the vault root. SPEC.md §3.7.
///
/// Sync clients (iCloud Drive, Dropbox, Syncthing) write in bursts, so events
/// are coalesced by the stream latency (~200 ms) before the callback fires.
final class VaultWatcher {

    private var stream: FSEventStreamRef?
    private let onChange: ([URL]) -> Void

    init(root: URL, onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.onChange(list.prefix(count).map { URL(fileURLWithPath: $0) })
        }

        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                     [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.2,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                                              | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
