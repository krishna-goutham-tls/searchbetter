import CoreServices
import Foundation

/// Reports every file created, changed, renamed or deleted under the given folders.
/// macOS sends these events itself (FSEvents), so watching costs almost nothing.
final class Watcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(roots: [String], onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.onChange(Array(arr.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil, callback, &ctx, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
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
