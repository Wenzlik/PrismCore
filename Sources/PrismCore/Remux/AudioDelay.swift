import Foundation
import CoreMedia

enum AudioDelay {
    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(2, max(-2, value)) : 0
    }

    static func shifted(_ sample: CMSampleBuffer, seconds: Double) throws -> CMSampleBuffer {
        guard seconds != 0 else { return sample }
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let offset = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isNumeric { timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + offset }
            if timing[index].decodeTimeStamp.isNumeric { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + offset }
        }
        var result: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result)
        guard status == noErr, let result else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result
    }
}
