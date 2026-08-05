import Testing
import Foundation
@testable import PrismCore

// MARK: - hvcC fixtures with parameter-set arrays

/// Builds an `hvcC` whose 22-byte header is a real Main10 PTL and whose arrays
/// are whatever the test asks for.
///
/// - Parameter arrays: `(nalType, arrayCompleteness, [nalPayload])` in the order
///   they should be written.
private func hvcC(
    lengthSizeMinusOne: UInt8 = 3,
    arrays: [(type: UInt8, complete: Bool, units: [[UInt8]])]
) -> Data {
    var bytes = [UInt8](repeating: 0, count: 22)
    bytes[0] = 1                     // configurationVersion
    bytes[1] = 2                     // profile_space 0, tier 0, profile_idc 2
    bytes[2] = 0x20                  // compatibility flags 0x20000000
    bytes[6] = 0xB0                  // first constraint byte
    bytes[12] = 153                  // level_idc 5.1
    bytes[21] = lengthSizeMinusOne   // constantFrameRate/etc zero + lengthSizeMinusOne

    bytes.append(UInt8(arrays.count))
    for array in arrays {
        bytes.append((array.complete ? 0x80 : 0x00) | array.type)
        bytes.append(UInt8((array.units.count >> 8) & 0xFF))
        bytes.append(UInt8(array.units.count & 0xFF))
        for unit in array.units {
            bytes.append(UInt8((unit.count >> 8) & 0xFF))
            bytes.append(UInt8(unit.count & 0xFF))
            bytes.append(contentsOf: unit)
        }
    }
    return Data(bytes)
}

private let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01]
private let sps: [UInt8] = [0x42, 0x01, 0x01, 0x02, 0x20]
private let pps: [UInt8] = [0x44, 0x01, 0xC0]
private let prefixSEI: [UInt8] = [0x4E, 0x01, 0x05, 0xFF]

/// Reads back the `(type, complete, units)` triples of a record.
private func arrays(of data: Data) -> [(type: UInt8, complete: Bool, units: [[UInt8]])] {
    let bytes = [UInt8](data)
    var result: [(type: UInt8, complete: Bool, units: [[UInt8]])] = []
    var cursor = 23
    guard bytes.count > 22 else { return result }
    for _ in 0..<Int(bytes[22]) {
        guard cursor + 3 <= bytes.count else { break }
        let header = bytes[cursor]
        let count = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
        cursor += 3
        var units: [[UInt8]] = []
        for _ in 0..<count {
            guard cursor + 2 <= bytes.count else { break }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            guard cursor + length <= bytes.count else { break }
            units.append(Array(bytes[cursor..<(cursor + length)]))
            cursor += length
        }
        result.append((type: header & 0x3F, complete: header & 0x80 != 0, units: units))
    }
    return result
}

// MARK: - hvcC normalization

@Suite("hvcC normalization")
struct HVCCNormalizerTests {

    @Test("a record that is already hvc1-correct is left alone")
    func noChangeReturnsNil() {
        let record = hvcC(arrays: [
            (type: 32, complete: true, units: [vps]),
            (type: 33, complete: true, units: [sps]),
            (type: 34, complete: true, units: [pps]),
        ])
        #expect(HVCCNormalizer.normalize(hvcC: record) == nil)
    }

    @Test("array_completeness=0 is raised to 1")
    func completenessIsAsserted() throws {
        let record = hvcC(arrays: [
            (type: 32, complete: false, units: [vps]),
            (type: 33, complete: false, units: [sps]),
            (type: 34, complete: false, units: [pps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        // Computed outside the macro: #expect decomposes a trailing function call
        // into a rethrows helper, and a key-path-as-function argument reads as
        // throwing there.
        let completeness = arrays(of: normalized).map(\.complete)
        #expect(completeness == [true, true, true])
    }

    @Test("SEI arrays are dropped, VPS/SPS/PPS survive in order")
    func seiIsDropped() throws {
        let record = hvcC(arrays: [
            (type: 33, complete: true, units: [sps]),
            (type: 39, complete: true, units: [prefixSEI]),
            (type: 32, complete: true, units: [vps]),
            (type: 34, complete: true, units: [pps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        let result = arrays(of: normalized)
        #expect(result.map(\.type) == [32, 33, 34])
        #expect(result.map(\.units) == [[vps], [sps], [pps]])
    }

    @Test("out-of-order arrays are reordered even when otherwise correct")
    func reordering() throws {
        let record = hvcC(arrays: [
            (type: 34, complete: true, units: [pps]),
            (type: 33, complete: true, units: [sps]),
            (type: 32, complete: true, units: [vps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        #expect(arrays(of: normalized).map(\.type) == [32, 33, 34])
    }

    @Test("two arrays of the same type are merged, keeping every parameter set")
    func mergesSplitArrays() throws {
        let secondSPS: [UInt8] = [0x42, 0x01, 0x02, 0x03]
        let record = hvcC(arrays: [
            (type: 32, complete: true, units: [vps]),
            (type: 33, complete: true, units: [sps]),
            (type: 33, complete: true, units: [secondSPS]),
            (type: 34, complete: true, units: [pps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        let result = arrays(of: normalized)
        #expect(result.map(\.type) == [32, 33, 34])
        #expect(result[1].units == [sps, secondSPS])
    }

    @Test("the profile_tier_level header survives byte for byte")
    func headerIsUntouched() throws {
        let record = hvcC(arrays: [
            (type: 33, complete: false, units: [sps]),
        ])
        let normalized = try #require(HVCCNormalizer.normalize(hvcC: record))
        #expect(normalized.prefix(22) == record.prefix(22))
        // Which is the property that matters: the CODECS string is printed from
        // this header, and it must still describe the init segment.
        let before = try #require(HEVCConfigurationRecord.parse(hvcC: record))
        let after = try #require(HEVCConfigurationRecord.parse(hvcC: normalized))
        #expect(before == after)
    }

    @Test("a record with no SPS is refused rather than rewritten")
    func refusesRecordWithoutSPS() {
        let record = hvcC(arrays: [(type: 39, complete: false, units: [prefixSEI])])
        #expect(HVCCNormalizer.normalize(hvcC: record) == nil)
    }

    @Test("truncated arrays are refused")
    func refusesTruncated() {
        var bytes = [UInt8](hvcC(arrays: [(type: 33, complete: false, units: [sps])]))
        bytes.removeLast(3)
        #expect(HVCCNormalizer.normalize(hvcC: Data(bytes)) == nil)
    }

    @Test("lengthSizeMinusOne is read back as the NAL prefix width")
    func lengthSizeIsRead() {
        #expect(HEVCNALUnits.lengthSize(fromHVCC: hvcC(lengthSizeMinusOne: 3, arrays: [])) == 4)
        #expect(HEVCNALUnits.lengthSize(fromHVCC: hvcC(lengthSizeMinusOne: 1, arrays: [])) == 2)
    }
}

// MARK: - NAL walking and rewriting

/// Length-prefixes NAL units the way a demuxed mp4/mkv packet carries them.
private func packet(_ units: [[UInt8]], lengthSize: Int = 4) -> [UInt8] {
    var bytes: [UInt8] = []
    for unit in units {
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8((unit.count >> shift) & 0xFF))
        }
        bytes.append(contentsOf: unit)
    }
    return bytes
}

/// An HEVC NAL header for `type` / `layerID`, plus one payload byte.
private func nal(type: UInt8, layerID: UInt8 = 0, payload: UInt8 = 0xAA) -> [UInt8] {
    [
        (type << 1) | ((layerID >> 5) & 0x01),
        ((layerID & 0x1F) << 3) | 1,
        payload,
    ]
}

@Suite("HEVC NAL units")
struct HEVCNALUnitsTests {

    @Test("types and layer ids are read out of the two-byte header")
    func parsesHeaders() throws {
        let bytes = packet([
            nal(type: 33),
            nal(type: 62),
            nal(type: 1, layerID: 1),
        ])
        let units = try #require(HEVCNALUnits.units(in: bytes, lengthSize: 4))
        #expect(units.map(\.type) == [33, 62, 1])
        #expect(units.map(\.layerID) == [0, 0, 1])
    }

    @Test("every prefix width frames the same units", arguments: [1, 2, 4])
    func everyLengthSize(lengthSize: Int) throws {
        let bytes = packet([nal(type: 33), nal(type: 34)], lengthSize: lengthSize)
        let units = try #require(HEVCNALUnits.units(in: bytes, lengthSize: lengthSize))
        #expect(units.map(\.type) == [33, 34])
    }

    @Test("a keep-everything rewrite reports no change")
    func keepIsNil() {
        let bytes = packet([nal(type: 33), nal(type: 1)])
        #expect(HEVCNALUnits.rewrite(bytes, lengthSize: 4) { _ in .keep } == nil)
    }

    @Test("dropping a unit removes it and its length prefix")
    func dropsUnits() throws {
        let bytes = packet([nal(type: 1), nal(type: 62), nal(type: 1, payload: 0xBB)])
        let rewritten = try #require(
            HEVCNALUnits.rewrite(bytes, lengthSize: 4) { $0.type == 62 ? .drop : .keep }
        )
        let units = try #require(HEVCNALUnits.units(in: rewritten, lengthSize: 4))
        #expect(units.map(\.type) == [1, 1])
        #expect(rewritten.count == bytes.count - (4 + 3))
    }

    @Test("a replacement of a different length is re-framed correctly")
    func replacesUnits() throws {
        let bytes = packet([nal(type: 62), nal(type: 1)])
        let longer = nal(type: 62) + [0x01, 0x02, 0x03]
        let rewritten = try #require(
            HEVCNALUnits.rewrite(bytes, lengthSize: 4) {
                $0.type == 62 ? .replace(longer) : .keep
            }
        )
        let units = try #require(HEVCNALUnits.units(in: rewritten, lengthSize: 4))
        #expect(units.count == 2)
        #expect(Array(units[0].bytes) == longer)
        #expect(units[1].type == 1)
    }

    @Test("a length that overruns the buffer is refused, not best-effort parsed")
    func refusesOverrun() {
        var bytes = packet([nal(type: 33)])
        bytes.removeLast()
        #expect(HEVCNALUnits.units(in: bytes, lengthSize: 4) == nil)
    }

    @Test("a zero length is refused rather than looping forever")
    func refusesZeroLength() {
        #expect(HEVCNALUnits.units(in: [0, 0, 0, 0, 0x42, 0x01], lengthSize: 4) == nil)
    }
}

// MARK: - Profile 7 declaration

@Suite("Profile 7 → 8.1 declaration")
struct DolbyVisionConversionDeclarationTests {

    private func profile7() -> DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: 1,
            versionMinor: 0,
            profile: 7,
            level: 6,
            rpuPresent: true,
            enhancementLayerPresent: true,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 0
        )
    }

    @Test("the converted configuration is single-layer 8.1 at the same level")
    func convertedShape() {
        let converted = profile7().convertedToProfile81
        #expect(converted.profile == 8)
        #expect(converted.baseLayerSignalCompatibilityID == 1)
        #expect(converted.level == 6)
        #expect(converted.enhancementLayerPresent == false)
        #expect(converted.isDualLayer == false)
        #expect(converted.profileName == "8.1")
    }

    @Test("a converted P7 earns the db1p supplemental claim a raw P7 cannot")
    func supplementalCodecs() throws {
        let record = try #require(
            HEVCConfigurationRecord.parse(
                hvcC: hvcC(arrays: [(type: 33, complete: true, units: [sps])])
            )
        )
        func variant(
            dolbyVision: DolbyVisionConfiguration
        ) -> MasterPlaylistBuilder.VariantDescription {
            MasterPlaylistBuilder.VariantDescription(
                bandwidth: 30_000_000,
                resolution: .init(width: 3840, height: 2160),
                frameRate: 23.976,
                dynamicRange: .pq,
                videoCodec: .hevc(record),
                dolbyVision: dolbyVision,
                displayIsDolbyVisionCapable: true,
                audioRenditions: [.init(name: "English", codecString: "ec-3", uri: "audio0/index.m3u8")]
            )
        }

        // Dual-layer P7 has no brand: nothing honest to claim, so no
        // SUPPLEMENTAL-CODECS at all.
        #expect(
            MasterPlaylistBuilder.supplementalCodecsString(for: variant(dolbyVision: profile7()))
                == nil
        )
        // Converted, it is a normal 8.1 stream with an HDR10 base.
        #expect(
            MasterPlaylistBuilder.supplementalCodecsString(
                for: variant(dolbyVision: profile7().convertedToProfile81)
            ) == "dvh1.08.06/db1p"
        )
    }

    @Test("the primary codec stays the HEVC base — 8.1 is not profile 5")
    func primaryCodecIsBase() throws {
        let record = try #require(
            HEVCConfigurationRecord.parse(
                hvcC: hvcC(arrays: [(type: 33, complete: true, units: [sps])])
            )
        )
        let variant = MasterPlaylistBuilder.VariantDescription(
            bandwidth: 30_000_000,
            frameRate: 23.976,
            dynamicRange: .pq,
            videoCodec: .hevc(record),
            dolbyVision: profile7().convertedToProfile81,
            displayIsDolbyVisionCapable: true
        )
        #expect(MasterPlaylistBuilder.primaryVideoCodecString(for: variant).hasPrefix("hvc1."))
    }
}

// MARK: - Normalization end to end

/// Walks an ISO-BMFF box tree looking for `hvcC`, returning its payload.
///
/// Deliberately dumb: descends only the containers that lead to a sample entry
/// (`moov` → `trak` → `mdia` → `minf` → `stbl` → `stsd`), and treats an `hvc1` /
/// `hev1` sample entry as a container whose children start 78 bytes in (the
/// `VisualSampleEntry` fixed fields). Enough to read our own init segment; not a
/// general parser.
private func findHVCC(in data: Data) -> Data? {
    func walk(_ range: Range<Int>, insideSampleEntry: Bool) -> Data? {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size = Int(data[cursor]) << 24 | Int(data[cursor + 1]) << 16
                | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            guard size >= 8, cursor + size <= range.upperBound else { return nil }
            let payload = (cursor + 8)..<(cursor + size)

            if type == "hvcC" { return data.subdata(in: payload) }
            switch type {
            case "moov", "trak", "mdia", "minf", "stbl":
                if let found = walk(payload, insideSampleEntry: false) { return found }
            case "stsd":
                // version/flags(4) + entry_count(4), then the sample entries.
                if payload.count > 8,
                   let found = walk((payload.lowerBound + 8)..<payload.upperBound,
                                    insideSampleEntry: true) {
                    return found
                }
            case "hvc1", "hev1", "dvh1", "dvhe":
                if payload.count > 78,
                   let found = walk((payload.lowerBound + 78)..<payload.upperBound,
                                    insideSampleEntry: false) {
                    return found
                }
            default:
                break
            }
            cursor += size
        }
        return nil
    }
    return walk(0..<data.count, insideSampleEntry: false)
}

@Suite("hvcC normalization, end to end")
struct HVCCNormalizationIntegrationTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("the served init segment's hvcC is in hvc1 form, whatever the source's was")
    func servedRecordIsNormalized() async throws {
        let source = try fixture("hevc_eac3.mkv")
        let session = try PrismCoreSession(url: source)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // The init segment is what AVPlayer parses the sample entry out of, so
        // it — not our in-memory record — is what has to be right.
        let initURL = playlist.deletingLastPathComponent().appendingPathComponent("init.mp4")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var initSegment = Data()
        while ContinuousClock.now < deadline {
            if let (data, response) = try? await URLSession.shared.data(from: initURL),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                initSegment = data
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let served = try #require(findHVCC(in: initSegment), "no hvcC in the served init segment")

        // The property that matters: nothing left to normalize. Every array is
        // complete, none is an SEI array, and they are in VPS/SPS/PPS order.
        #expect(HVCCNormalizer.normalize(hvcC: served) == nil)

        // And the PTL still describes the same stream — normalization must never
        // change what the CODECS string says.
        let sourceInfo = try SourceProbe.probe(url: source)
        let sourceRecord = try #require(sourceInfo.video?.hevcConfiguration)
        let servedRecord = try #require(HEVCConfigurationRecord.parse(hvcC: served))
        #expect(sourceRecord == servedRecord)
    }
}

// MARK: - Master rejection

@Suite("Master rejection")
struct MasterRejectionTests {

    @Test("each rejection code matches", arguments: [-11868, -11848, -1002])
    func matchesCodes(code: Int) {
        let error = NSError(domain: "AVFoundationErrorDomain", code: code)
        #expect(MasterRejection.matches(error))
        #expect(PrismCoreSession.isMasterRejection(error))
    }

    @Test("a code nested under NSUnderlyingErrorKey still matches")
    func matchesNested() {
        let underlying = NSError(domain: NSURLErrorDomain, code: -1002)
        let wrapper = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(MasterRejection.matches(wrapper))
    }

    @Test("an unrelated failure does not match")
    func ignoresOthers() {
        #expect(!MasterRejection.matches(NSError(domain: NSURLErrorDomain, code: -1009)))
        #expect(!MasterRejection.matches(nil))
    }

    @Test("a cyclic underlying-error chain terminates")
    func toleratesCycle() {
        // Two errors referencing each other: the depth bound is what keeps a
        // host's failure handler from hanging on framework-supplied input.
        let inner = NSError(domain: "A", code: 1)
        let outer = NSError(domain: "B", code: 2, userInfo: [NSUnderlyingErrorKey: inner])
        let cyclic = NSError(domain: "C", code: 3, userInfo: [NSUnderlyingErrorKey: outer])
        #expect(!MasterRejection.matches(cyclic))
    }
}

// MARK: - Display capabilities

@Suite("Display capabilities")
struct DisplayCapabilitiesTests {

    @Test("the conservative default claims nothing")
    func conservative() {
        #expect(DisplayCapabilities.conservative.isHDRReady == false)
        #expect(DisplayCapabilities.conservative.isDolbyVisionCapable == false)
        #expect(DisplayCapabilities.conservative.source == .unavailable)
    }

    @Test("a caller-supplied pair is reported as caller-sourced")
    func callerSourced() {
        let capabilities = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
        #expect(capabilities.source == .caller)
    }

    @Test("reading the current display answers without crashing")
    @MainActor
    func currentIsReadable() {
        // What it *says* depends on the machine running the suite (and a headless
        // CI host has no screen at all), so the assertion is only that the read
        // completes and reports where it came from. The values themselves need a
        // device to verify — see the README's Status section.
        let capabilities = DisplayCapabilities.current()
        #expect(capabilities.source != .caller)
        if capabilities.isDolbyVisionCapable {
            #expect(capabilities.isHDRReady, "DV without HDR is not a reachable state")
        }
    }
}

// MARK: - Atmos declaration

@Suite("Atmos / CHANNELS=16/JOC")
struct ObjectAudioDeclarationTests {

    @Test("object audio prints the JOC form, not the bed's channel count")
    func jocWinsOverCount() {
        // An Atmos EAC3 track's ch_layout really does read 6; 16 is the fixed
        // figure HLS asks for, so the count must NOT win here.
        #expect(
            MasterPlaylistBuilder.channelsAttribute(channelCount: 6, isObjectAudio: true)
                == "16/JOC"
        )
        #expect(
            MasterPlaylistBuilder.channelsAttribute(channelCount: nil, isObjectAudio: true)
                == "16/JOC"
        )
    }

    @Test("without object audio it is the plain count, and nothing when unknown")
    func plainCount() {
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: 6, isObjectAudio: false) == "6")
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: 2, isObjectAudio: false) == "2")
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: nil, isObjectAudio: false) == nil)
        // A container that reports zero channels knows nothing; CHANNELS is
        // optional, and omitting it beats declaring a lie.
        #expect(MasterPlaylistBuilder.channelsAttribute(channelCount: 0, isObjectAudio: false) == nil)
    }

    @Test("an Atmos rendition reaches the master as CHANNELS=\"16/JOC\"")
    func masterCarriesJOC() throws {
        let record = try #require(
            HEVCConfigurationRecord.parse(
                hvcC: hvcC(arrays: [(type: 33, complete: true, units: [sps])])
            )
        )
        let variant = MasterPlaylistBuilder.VariantDescription(
            bandwidth: 30_000_000,
            frameRate: 23.976,
            videoCodec: .hevc(record),
            audioRenditions: [
                .init(
                    name: "English",
                    codecString: "ec-3",
                    channels: MasterPlaylistBuilder.channelsAttribute(
                        channelCount: 6, isObjectAudio: true
                    ),
                    uri: "audio0/index.m3u8"
                )
            ]
        )
        let master = try MasterPlaylistBuilder.build(variant)
        #expect(master.contains("CHANNELS=\"16/JOC\""))
        // The codec tag stays plain EAC3 — JOC is not a codec, it rides inside.
        #expect(master.contains("ec-3"))
    }
}
