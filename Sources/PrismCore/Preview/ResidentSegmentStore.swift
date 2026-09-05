import Foundation

/// A completed video segment's source-time interval. This describes disk
/// residency, not AVPlayer's buffer or a guarantee of an instantaneous seek.
public struct ResidentRange: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
}

/// Serializes snapshots with retirement so a preview never borrows files
/// that an eviction can remove halfway through its read.
final class ResidentSegmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: ResidentRange] = [:]
    private var stopped = false

    func record(index: Int, start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        lock.withLock {
            guard !stopped else { return }
            entries[index] = ResidentRange(startSeconds: start, endSeconds: end)
        }
    }

    func retire(_ indexes: [Int]) {
        lock.withLock { for index in indexes { entries.removeValue(forKey: index) } }
    }

    func publish(index: Int, start: Double, end: Double, data: Data, root: URL) throws {
        try lock.withLock {
            try data.write(to: root.appendingPathComponent(String(format: "seg%05d.m4s", index)), options: .atomic)
            if !stopped, start.isFinite, end.isFinite, end > start {
                entries[index] = ResidentRange(startSeconds: start, endSeconds: end)
            }
        }
    }

    func unlinkRetired(index: Int, directories: [URL]) {
        lock.withLock {
            // A queued unlink may outlive a re-production of this index.
            guard entries[index] == nil else { return }
            let name = String(format: "seg%05d.m4s", index)
            for directory in directories {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    func clear() {
        lock.withLock { stopped = true; entries.removeAll() }
    }

    var ranges: [ResidentRange] {
        lock.withLock {
            var result: [ResidentRange] = []
            for range in entries.values.sorted(by: { $0.startSeconds < $1.startSeconds }) {
                if let last = result.last, range.startSeconds <= last.endSeconds + 0.000_001 {
                    result[result.count - 1] = ResidentRange(
                        startSeconds: last.startSeconds,
                        endSeconds: max(last.endSeconds, range.endSeconds)
                    )
                } else { result.append(range) }
            }
            return result
        }
    }

    func snapshot(at seconds: Double, root: URL) -> (index: Int, data: Data)? {
        guard seconds.isFinite else { return nil }
        return lock.withLock {
            guard !stopped, let entry = entries.first(where: {
                seconds >= $0.value.startSeconds && seconds < $0.value.endSeconds
            }) else { return nil }
            let mediaURL = root.appendingPathComponent(String(format: "seg%05d.m4s", entry.key))
            // A very long GOP can make one fragment enormous. Previewing it
            // must not allocate an unbounded second copy beside playback.
            guard let size = try? mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 64 << 20,
                  let initial = try? Data(contentsOf: root.appendingPathComponent("init.mp4")),
                  let media = try? Data(contentsOf: mediaURL)
            else { return nil }
            return (entry.key, initial + media)
        }
    }
}
