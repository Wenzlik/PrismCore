import Foundation
import Testing
import Libavformat
@testable import PrismCore

struct SourceOpenerTests {
    private enum Marker: Error { case failure }

    private struct BrokenInput: PrismCoreInput {
        let length: Int64? = 1_024
        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { throw Marker.failure }
        func seek(to offset: Int64) throws {}
    }

    @Test func sourceOpenerOptionsPreserveHeadersAndCaps() {
        var headersOnly: OpaquePointer?
        defer { av_dict_free(&headersOnly) }
        SourceOpenTuning.applyHTTPHeaders([:], to: &headersOnly)
        #expect(headersOnly == nil)
        SourceOpenTuning.applyHTTPHeaders(["Authorization": "test-token"], to: &headersOnly)
        #expect(avMetadataValue(headersOnly, "headers") == "Authorization: test-token\r\n")
        #expect(av_dict_count(headersOnly) == 1)

        var options = SourceOpenTuning.makeOptions(httpHeaders: ["Authorization": "test-token"])
        defer { av_dict_free(&options) }
        #expect(avMetadataValue(options, "headers") == avMetadataValue(headersOnly, "headers"))
        #expect(avMetadataValue(options, "reconnect") == "1")
        #expect(avMetadataValue(options, "reconnect_streamed") == "1")
        #expect(avMetadataValue(options, "probesize") == "4194304")
        #expect(avMetadataValue(options, "analyzeduration") == "2000000")
        #expect(av_dict_count(options) == 5)
    }

    @Test func sourceOpenerKeepsPhaseSpecificErrorWrapping() throws {
        let readGuard = ReadInterruptGuard()
        let error = FFmpegError(code: -22, operation: "test")
        for phase in [SourceOpener.Phase.open, .interrupted] {
            let mapped = SourceOpener.Policy.probe.failure(error, phase: phase, guard: readGuard)
            guard case SourceProbe.Failure.openFailed(let underlying) = mapped else {
                Issue.record("probe did not wrap \(phase): \(mapped)")
                continue
            }
            #expect((underlying as? FFmpegError)?.code == -22)
        }
        #expect(SourceOpener.Policy.probe.failure(error, phase: .streamInfo, guard: readGuard) is FFmpegError)
        for policy in [SourceOpener.Policy.remux, .software, .preview] {
            #expect(policy.failure(error, phase: .open, guard: readGuard) is FFmpegError)
        }
    }

    @Test func sourceOpenerPreservesHostFailurePrecedence() {
        for policy in [SourceOpener.Policy.remux, .software, .probe, .preview] {
            let readGuard = ReadInterruptGuard()
            defer { readGuard.disarm() }
            do {
                _ = try SourceOpener.open(
                    url: URL(fileURLWithPath: "/prismcore-tests-absent/source.mkv"),
                    httpHeaders: [:], coordinatedHTTP: true, inputFactory: { BrokenInput() },
                    interruptGuard: readGuard, budget: .seconds(1), policy: policy
                )
                Issue.record("broken input opened")
            } catch {
                let underlying: any Error
                if case SourceProbe.Failure.openFailed(let inner) = error { underlying = inner }
                else { underlying = error }
                if policy == .software {
                    #expect(underlying is FFmpegError)
                } else if case PrismCoreInputError.readFailed(let host) = underlying {
                    #expect(host is Marker)
                } else {
                    Issue.record("lost host failure: \(error)")
                }
            }
        }
    }

    @Test func sourceOpenerInstallsInterruptBeforeOpen() throws {
        let url = try #require(Bundle.module.url(forResource: "vp9", withExtension: "webm", subdirectory: "Fixtures"))
        for policy in [SourceOpener.Policy.remux, .software, .probe, .preview] {
            let readGuard = ReadInterruptGuard()
            readGuard.cancel()
            defer { readGuard.disarm() }
            do {
                _ = try SourceOpener.open(url: url, httpHeaders: [:], coordinatedHTTP: false,
                                          interruptGuard: readGuard, budget: .seconds(1), policy: policy)
                Issue.record("cancelled open succeeded")
            } catch {
                let underlying: any Error
                if case SourceProbe.Failure.openFailed(let inner) = error { underlying = inner }
                else { underlying = error }
                #expect((underlying as? FFmpegError)?.code == swift_AVERROR_EXIT())
            }
        }
    }
}
