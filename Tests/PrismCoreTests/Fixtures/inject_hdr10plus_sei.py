#!/usr/bin/env python3
"""Insert an ST 2094-40 (HDR10+) prefix SEI before every picture of an
Annex-B HEVC elementary stream.

Exists because no encoder available to CI writes HDR10+ (the x265 in common
package managers is built without --dhdr10-info), and a fixture that only
*claims* HDR10+ would test nothing: the scout reads the bitstream, so the
bitstream has to carry the real message. ffprobe decoding the result as
"HDR Dynamic Metadata SMPTE2094-40 (HDR10+)" frame side data is the
independent check that the bytes are the real syntax, not our reading of it.

usage: inject_hdr10plus_sei.py in.hevc out.hevc
"""
import sys


class Bits:
    def __init__(self):
        self.bits = []

    def put(self, value, width):
        for shift in range(width - 1, -1, -1):
            self.bits.append((value >> shift) & 1)

    def bytes(self):
        while len(self.bits) % 8:
            self.bits.append(0)
        return bytes(
            int("".join(map(str, self.bits[i:i + 8])), 2)
            for i in range(0, len(self.bits), 8)
        )


def t35_payload():
    b = Bits()
    b.put(0xB5, 8)      # itu_t_t35_country_code: United States
    b.put(0x003C, 16)   # terminal_provider_code: Samsung
    b.put(0x0001, 16)   # terminal_provider_oriented_code
    b.put(4, 8)         # application_identifier: ST 2094-40
    b.put(1, 8)         # application_version
    b.put(1, 2)         # num_windows
    b.put(400, 27)      # targeted_system_display_maximum_luminance
    b.put(0, 1)         # targeted_system_display_actual_peak_luminance_flag
    for maxscl in (40000, 38000, 36000):
        b.put(maxscl, 17)
    b.put(12000, 17)    # average_maxrgb
    percentiles = [(1, 100), (5, 900), (10, 2000), (25, 5000), (50, 10000),
                   (75, 20000), (90, 30000), (95, 35000), (99, 39000)]
    b.put(len(percentiles), 4)
    for percentage, percentile in percentiles:
        b.put(percentage, 7)
        b.put(percentile, 17)
    b.put(0, 10)        # fraction_bright_pixels
    b.put(0, 1)         # mastering_display_actual_peak_luminance_flag
    b.put(1, 1)         # tone_mapping_flag
    b.put(2048, 12)     # knee_point_x
    b.put(2048, 12)     # knee_point_y
    anchors = [102, 205, 307, 410, 512, 614, 717, 819, 922]
    b.put(len(anchors), 4)
    for anchor in anchors:
        b.put(anchor, 10)
    b.put(0, 1)         # color_saturation_mapping_flag
    return b.bytes()


def escape(rbsp):
    out = bytearray()
    zeros = 0
    for byte in rbsp:
        if zeros >= 2 and byte <= 3:
            out.append(3)
            zeros = 0
        out.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(out)


def sei_nal():
    payload = t35_payload()
    assert len(payload) < 255
    rbsp = bytes([4, len(payload)]) + payload + b"\x80"
    # nal_unit_type 39 (PREFIX_SEI_NUT), layer 0, temporal_id_plus1 1.
    return b"\x00\x00\x00\x01" + bytes([39 << 1, 0x01]) + escape(rbsp)


def nal_units(stream):
    starts = []
    i = 0
    while True:
        i = stream.find(b"\x00\x00\x01", i)
        if i < 0:
            break
        starts.append(i + 3)
        i += 3
    for index, start in enumerate(starts):
        end = starts[index + 1] - 3 if index + 1 < len(starts) else len(stream)
        while end > start and stream[end - 1] == 0:
            end -= 1
        yield stream[start:end]


def main():
    source = open(sys.argv[1], "rb").read()
    sei = sei_nal()
    out = bytearray()
    for nal in nal_units(source):
        nal_type = (nal[0] >> 1) & 0x3F
        # A VCL unit whose first_slice_segment_in_pic_flag is set opens a
        # picture; the SEI goes right before it, after any parameter sets.
        if nal_type < 32 and nal[2] & 0x80:
            out += sei
        out += b"\x00\x00\x00\x01" + nal
    open(sys.argv[2], "wb").write(bytes(out))


if __name__ == "__main__":
    main()
