import CoreServices
import Foundation

/// Recursive macOS file system watcher backed by CoreServices `FSEventStream`.
final class FSEventsWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let onChange: @Sendable ([String]) -> Void

        init(onChange: @escaping @Sendable ([String]) -> Void) {
            self.onChange = onChange
        }
    }

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?
    private let queue = DispatchQueue(label: "com.HR.MarkPocketSync.fsevents", qos: .utility)

    deinit {
        stop()
    }

    func start(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        stop()

        let validPaths = Array(Set(paths)).filter { FileManager.default.fileExists(atPath: $0) }
        guard !validPaths.isEmpty else { return }

        let box = CallbackBox(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPathsPointer, _, _ in
            guard let info = clientCallBackInfo else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()

            guard let cfArray = unsafeBitCast(eventPathsPointer, to: CFArray?.self) else {
                box.onChange([])
                return
            }
            var changedPaths: [String] = []
            changedPaths.reserveCapacity(numEvents)
            for idx in 0..<numEvents {
                if let rawPtr = CFArrayGetValueAtIndex(cfArray, idx) {
                    let cfStr = unsafeBitCast(rawPtr, to: CFString.self)
                    changedPaths.append(cfStr as String)
                }
            }
            box.onChange(changedPaths)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            validPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else {
            return
        }

        lock.lock()
        self.callbackBox = box
        self.stream = createdStream
        lock.unlock()

        FSEventStreamSetDispatchQueue(createdStream, queue)
        FSEventStreamStart(createdStream)
    }

    func stop() {
        lock.lock()
        let currentStream = stream
        stream = nil
        callbackBox = nil
        lock.unlock()

        guard let currentStream else { return }
        FSEventStreamStop(currentStream)
        FSEventStreamInvalidate(currentStream)
        FSEventStreamRelease(currentStream)
    }
}
