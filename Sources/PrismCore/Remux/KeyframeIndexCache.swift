import CryptoKit
import Foundation
import Libavformat

/// The host's own name for one version of one source, keying the keyframe
/// sidecar (`keyframeIndexCacheDirectory`) instead of the address the engine
/// was handed.
///
/// The URL-based identity cannot survive an address that changes between
/// launches while the bytes stay put — a host's localhost range proxy on a
/// fresh port with a fresh token is exactly that, so every app restart was a
/// cache miss. A host that knows which item it is playing, and holds a strong
/// validator for it from its own server's metadata, says so here, and the
/// sidecar then binds to *that*: the address, the transport and its `ETag`
/// stop mattering, so it works over FFmpeg's own HTTP and a host input as
/// well as the coordinated reader.
///
/// - `namespace`: whose `item` it is — a server ID, so two servers' item
///   numbers never meet.
/// - `item`: the item (or media part) on that server.
/// - `etag`: a **strong** validator of the item's bytes, as the server
///   reports it. A weak one (`W/…`) or an empty one is no proof of the same
///   bytes, so it turns the sidecar off for the source — never back to the
///   URL, which is the key the host is replacing.
///
/// The host vouches for it, so it must change whenever the bytes do: a map
/// trusted on a stale tag plans segment cuts on keyframes the new file does
/// not have. The byte size and container duration of the open still go into
/// the key beside it.
public struct SourceCacheIdentity: Sendable, Equatable {
    public var namespace: String
    public var item: String
    public var etag: String

    public init(namespace: String, item: String, etag: String) {
        self.namespace = namespace
        self.item = item
        self.etag = etag
    }

    /// Whether this identity can key a sidecar at all. Empty parts would let
    /// different items share a key; a weak or empty tag vouches for nothing.
    var vouchesForBytes: Bool {
        let tag = etag.trimmingCharacters(in: .whitespaces)
        return !namespace.isEmpty && !item.isEmpty && !tag.isEmpty
            && !tag.lowercased().hasPrefix("w/")
    }
}

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
/// Entries are keyed by an `Identity`: the full URL, byte size, container
/// duration and a `SourceVersion` — a local file's mtime, or a remote
/// origin's strong `ETag` — or, when the host names the source itself
/// (`SourceCacheIdentity`), that name and its strong `ETag` in place of the
/// URL and the transport's proof. A remote source with no strong `ETag` has no
/// identity at all and never touches the sidecar (see `Identity`). Only a
/// SHA-256 digest of all that is written, inside the entry and checked on
/// lookup, so the filename hash never has to be collision-free and a token in
/// the URL never lands on disk; a mismatch is simply a miss. Storage is
/// bounded LRU by entry count (a read refreshes the file's mtime), and an
/// entry that no longer matches its source invalidates itself by never
/// matching again.
struct KeyframeIndexCache: Sendable {

    /// The sidecar layout an entry was written in. 2 = keyed by
    /// `Identity.key`; entries before it (no field) were keyed by a readable
    /// URL with the query stripped and no version proof, and are misses —
    /// their key could not match anyway, this says so without relying on it.
    static let formatVersion = 2

    /// What vouches that the bytes behind an address are the ones a map was
    /// learned from. Deliberately only two kinds: anything weaker — a weak
    /// `ETag` (equivalent content, not the same bytes), a `Last-Modified`
    /// date (one-second resolution: a file replaced within the second keeps
    /// it) or nothing at all — is no proof, and a map trusted on it plans
    /// segment cuts and scrub frames from keyframes a replaced file no longer
    /// has.
    enum SourceVersion: Equatable, Sendable {
        /// A local file's modification time.
        case fileModified(TimeInterval)
        /// The strong `ETag` an origin reported on the open that read the
        /// bytes (`ReadInterruptGuard.openedStrongETag`), and the URL whose
        /// response carried it. A tag is unique per resource only, and after
        /// a redirect that resource is the target, which the host's URL does
        /// not name: an address that redirects elsewhere on the next open
        /// can meet the same tag on a different file.
        case strongETag(String, servedBy: URL)
        /// The host's name and strong `ETag` for the source. Replaces the
        /// URL in the key, not only the proof: the point is an address that
        /// changes between launches (see `SourceCacheIdentity`).
        case host(SourceCacheIdentity)

        /// The version an opened source can prove, or `nil`.
        ///
        /// A `file:` URL proves its version by the file's mtime — whichever
        /// reader delivered the bytes, the URL names a file this machine can
        /// stat, which is what local identity always meant. Every other URL
        /// needs the strong `ETag` the coordinated reader saw; FFmpeg's own
        /// HTTP and a host-supplied input report none, so they plan from the
        /// source every time rather than on a map nothing can bind to it.
        ///
        /// A host identity, when given, decides alone: a weak or empty tag in
        /// it is `nil` rather than a fall back to the URL, because the host
        /// supplying one is saying the URL is not the source's name.
        static func observed(
            sourceURL: URL, strongETag: (tag: String, url: URL)?, host: SourceCacheIdentity? = nil
        ) -> SourceVersion? {
            if let host { return host.vouchesForBytes ? .host(host) : nil }
            if sourceURL.isFileURL {
                return ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path))?[
                    .modificationDate
                ] as? Date).map { .fileModified($0.timeIntervalSince1970) }
            }
            return strongETag.map { .strongETag($0.tag, servedBy: $0.url) }
        }
    }

    /// The stable identity of one version of one source.
    ///
    /// Its own value with a plain constructor, not a string assembled inside
    /// the remuxer, so that any independent open of the same source — the
    /// scrub preview's today — derives it the same way, and two opens can
    /// prove they read the same version by comparing two of these.
    struct Identity: Equatable, Sendable {
        /// Hex SHA-256 over every field, prefixed by the format. The only
        /// form ever written: the URL keeps its query (a query can select the
        /// media, not only carry a token), so the clear text may hold a
        /// credential.
        let key: String

        /// - Parameters:
        ///   - sourceURL: the address as the host gave it, query included.
        ///     A strong `ETag` is only unique per resource, so it never
        ///     stands without the URL it came from.
        ///   - sizeBytes / durationMicroseconds: from the opened context —
        ///     the transport's own size, the container's duration.
        init(
            sourceURL: URL, sizeBytes: Int64, durationMicroseconds: Int64,
            version: SourceVersion
        ) {
            let proof: String = switch version {
            case .fileModified(let mtime): "mtime:\(mtime)"
            case .strongETag(let tag, let servedBy): "etag:\(servedBy.absoluteString)\u{0}\(tag)"
            // Length-prefixed: host strings may hold a NUL, and
            // ("a\u{0}b", "c") must not key like ("a", "b\u{0}c").
            case .host(let host):
                "host:" + [host.namespace, host.item, host.etag].map { "\($0.utf8.count):\($0)" }.joined()
            }
            // A host-named source is keyed without its address — the one
            // thing that changes across launches. Empty, never a URL's
            // spelling, so it cannot meet a URL-keyed canonical.
            let address: String = if case .host = version { "" } else { sourceURL.absoluteString }
            // NUL-separated: no URL, number or ETag contains one, so two
            // different field lists cannot run together into one digest (a
            // proof's own NUL count is fixed by its kind).
            let canonical = [
                "v\(KeyframeIndexCache.formatVersion)",
                address,
                String(sizeBytes),
                // Whole seconds: the byte size already pins the bits, and the
                // sub-second part of a container duration is demuxer
                // arithmetic a caller reconstructing the identity shouldn't
                // have to match.
                String(durationMicroseconds / 1_000_000),
                proof,
            ].joined(separator: "\u{0}")
            key = SHA256.hash(data: Data(canonical.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }

        /// The identity of the source `context` was opened on, or `nil` when
        /// nothing vouches for its version (`SourceVersion.observed`) — the
        /// caller then neither looks up nor stores, and plans from the source.
        init?(
            opened context: UnsafeMutablePointer<AVFormatContext>, sourceURL: URL,
            interruptGuard: ReadInterruptGuard, host: SourceCacheIdentity? = nil
        ) {
            guard let version = SourceVersion.observed(
                sourceURL: sourceURL, strongETag: interruptGuard.openedStrongETag, host: host
            ) else { return nil }
            self.init(
                sourceURL: sourceURL,
                sizeBytes: context.pointee.pb.map { avio_size($0) } ?? -1,
                durationMicroseconds: context.pointee.duration,
                version: version
            )
        }
    }

    struct Entry: Codable, Equatable {
        /// The `Identity.key` the entry was stored under — the collision
        /// guard.
        var identity: String
        /// `KeyframeIndexCache.formatVersion` at write time; anything else is
        /// a miss.
        var format: Int = KeyframeIndexCache.formatVersion
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
            self.format = KeyframeIndexCache.formatVersion
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
            // Absent = written before the field existed (format 1).
            format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 1
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

    /// The stored entry for `identity`, or nil. A hit refreshes the entry's
    /// LRU position.
    func lookup(identity: String) -> Entry? {
        let url = fileURL(identity: identity)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.identity == identity, entry.format == Self.formatVersion
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
    ///
    /// Returns whether the cache now holds, for this identity, an entry at
    /// least as good as `entry` — `false` only when the write itself failed.
    /// A caller that *promises* the map to a host (the late index load's
    /// `.segmentPlanAvailable`) must not promise one an unwritable directory
    /// swallowed: the successor it invites would miss and stay sequential.
    @discardableResult
    func store(_ entry: Entry) -> Bool {
        // The compare-and-write is one critical section: two sessions of the
        // same source ending together could both pass the check below and
        // the shorter one land last (review finding). Process-wide, since
        // every session's cache value points at the same directory.
        Self.storeLock.lock()
        defer { Self.storeLock.unlock() }
        if !entry.complete, let existing = lookup(identity: entry.identity) {
            if existing.complete { return true }
            if (existing.coveredThroughPTS ?? .min) >= (entry.coveredThroughPTS ?? .min) { return true }
        }
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        do { try data.write(to: fileURL(identity: entry.identity), options: .atomic) } catch { return false }
        prune()
        return true
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
