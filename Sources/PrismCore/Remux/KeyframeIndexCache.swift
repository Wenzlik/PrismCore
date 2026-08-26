import Foundation

/// A cross-session sidecar cache of a source's video keyframe timestamps
/// (issue #34).
///
/// A container with no seek index — a Matroska without Cues, any MPEG-TS —
/// can never get a keyframe-basis plan from `SegmentPlan.build`: the map is
/// not in the file, and building one would mean reading the file. The bounded
/// index-load seek keeps that from stalling startup, but the source then
/// plays without demand mode at all, and pays the same degradation on every
/// play. The information is free, though: **the remux reads the whole file
/// sequentially and sees every keyframe go past.** The producer harvests them
/// as a by-product (never extra I/O — that is the non-goal line), and the
/// *next* play of the same source plans on a real index from its first
/// second, as if the file had Cues. A cache hit also skips the index-load
/// nudge seek entirely, which is a startup win even for well-indexed files.
///
/// Entries are keyed by a stable identity — URL (query stripped: a Plex
/// token rotates without the media changing), byte size, container duration,
/// and, for local files, mtime. The identity string is stored *inside* the
/// entry and checked on lookup, so the filename hash never has to be
/// collision-free; a mismatch is simply a miss. Storage is bounded LRU by
/// entry count (a read refreshes the file's mtime), and an entry that no
/// longer matches its source invalidates itself by never matching again.
struct KeyframeIndexCache: Sendable {

    struct Entry: Codable, Equatable {
        /// The full identity the entry was stored under — the collision guard.
        var identity: String
        /// The video stream's time base the PTS values live on. Checked on
        /// use: the same file demuxes to the same base, so a mismatch means
        /// the identity lied (or the demuxer changed) and the entry is junk.
        var timeBaseNum: Int32
        var timeBaseDen: Int32
        /// Every video keyframe PTS the producer saw, in decode order.
        var keyframePTS: [Int64]
        /// Whether the harvest ran head-to-EOF. A play cancelled partway
        /// persists what it saw (`complete == false`) so the next play can
        /// plan the watched prefix exactly instead of paying the sequential
        /// shape again; `coveredThroughPTS` is the last keyframe of the
        /// contiguous run, past which the map says nothing.
        var complete: Bool = true
        var coveredThroughPTS: Int64? = nil

        init(
            identity: String, timeBaseNum: Int32, timeBaseDen: Int32, keyframePTS: [Int64],
            complete: Bool = true, coveredThroughPTS: Int64? = nil
        ) {
            self.identity = identity
            self.timeBaseNum = timeBaseNum
            self.timeBaseDen = timeBaseDen
            self.keyframePTS = keyframePTS
            self.complete = complete
            self.coveredThroughPTS = coveredThroughPTS
        }

        // Entries written before `complete` existed were only ever stored at
        // EOF, so their absence of a flag means complete.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decode(String.self, forKey: .identity)
            timeBaseNum = try container.decode(Int32.self, forKey: .timeBaseNum)
            timeBaseDen = try container.decode(Int32.self, forKey: .timeBaseDen)
            keyframePTS = try container.decode([Int64].self, forKey: .keyframePTS)
            complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? true
            coveredThroughPTS = try container.decodeIfPresent(Int64.self, forKey: .coveredThroughPTS)
        }
    }

    let directory: URL
    /// LRU bound. Entries are a few KB (a 3 h film at a 5 s keyframe cadence
    /// is ~2200 numbers), so the bound is about hygiene, not disk pressure.
    var maxEntries: Int = 64

    /// The stable identity of a source, as seen from an OPENED context.
    ///
    /// The URL loses its query — session tokens rotate per play while the
    /// media stays the same — and gains the byte size and container duration,
    /// which together pin the actual bits closely enough that a same-path
    /// re-encode misses. Local files add mtime, the cheap signal a same-size
    /// in-place edit would otherwise dodge.
    static func identity(
        sourceURL: URL,
        sizeBytes: Int64,
        durationMicroseconds: Int64
    ) -> String {
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        var parts = [
            components?.url?.absoluteString ?? sourceURL.absoluteString,
            String(sizeBytes),
            // Whole seconds: the byte size already pins the bits, and the
            // sub-second part of a container duration is demuxer arithmetic
            // a caller reconstructing the identity shouldn't have to match.
            String(durationMicroseconds / 1_000_000),
        ]
        if sourceURL.isFileURL,
           let mtime = (try? FileManager.default.attributesOfItem(
               atPath: sourceURL.path
           ))?[.modificationDate] as? Date {
            parts.append(String(mtime.timeIntervalSince1970))
        }
        return parts.joined(separator: "|")
    }

    /// The stored entry for `identity`, or nil. A hit refreshes the entry's
    /// LRU position.
    func lookup(identity: String) -> Entry? {
        let url = fileURL(identity: identity)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.identity == identity
        else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
        return entry
    }

    /// Persist `entry`, creating the directory on first use and pruning the
    /// least-recently-used entries past the bound. Best-effort throughout: a
    /// cache that cannot write is a cache that misses, never an error the
    /// remux surfaces.
    ///
    /// A partial entry never overwrites a complete one for the same identity,
    /// and a partial one covering less than the stored partial does not
    /// replace it either: a short second play must not shrink what a longer
    /// first play learned.
    func store(_ entry: Entry) {
        // The compare-and-write is one critical section: two sessions of the
        // same source ending together could both pass the check below and
        // the shorter one land last (review finding). Process-wide, since
        // every session's cache value points at the same directory.
        Self.storeLock.lock()
        defer { Self.storeLock.unlock() }
        if !entry.complete, let existing = lookup(identity: entry.identity) {
            if existing.complete { return }
            if (existing.coveredThroughPTS ?? .min) >= (entry.coveredThroughPTS ?? .min) { return }
        }
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? data.write(to: fileURL(identity: entry.identity), options: .atomic)
        prune()
    }

    private static let storeLock = NSLock()

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ).filter({ $0.pathExtension == "json" }), files.count > maxEntries else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxEntries) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(identity: String) -> URL {
        directory.appendingPathComponent("\(Self.fnv1a(identity)).json")
    }

    /// FNV-1a 64 as a stable filename hash. `Hasher` is seeded per launch, so
    /// it cannot name files that outlive the process; collisions are harmless
    /// here because the entry carries its full identity.
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
