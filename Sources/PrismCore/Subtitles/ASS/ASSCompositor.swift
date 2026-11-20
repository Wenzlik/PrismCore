import Foundation
import CoreGraphics
import Libass

/// Flattens libass's `ASS_Image` list — one 8-bit coverage mask plus one
/// RGBA colour per glyph layer (fill, outline, shadow), back to front — into
/// a few premultiplied BGRA images a host can hand straight to a layer.
///
/// **Why regions, not one bitmap.** A top-of-frame sign and bottom dialogue
/// in one bounding box is most of a 4K canvas (33 MB) for two lines of
/// text. Layers whose padded rects touch are merged; separate clusters stay
/// separate images. The merge is O(n²) in layers, and a busy typeset frame
/// is a few hundred of them — microseconds next to the blend.
struct ASSCompositor {
    /// Layers closer than this merge into one region: fewer layers for the
    /// host than one image per glyph, without the empty-canvas cost.
    static let mergeDistance = 16

    struct Rect: Equatable {
        var minX, minY, maxX, maxY: Int
        var width: Int { maxX - minX }
        var height: Int { maxY - minY }
        func touches(_ other: Rect, within pad: Int) -> Bool {
            minX - pad < other.maxX && other.minX - pad < maxX && minY - pad < other.maxY && other.minY - pad < maxY
        }
        func union(_ other: Rect) -> Rect {
            Rect(minX: min(minX, other.minX), minY: min(minY, other.minY),
                 maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
        }
    }

    /// One visible layer, clipped to the canvas.
    struct Layer {
        var rect: Rect
        var bitmap: UnsafePointer<UInt8>
        var stride: Int
        /// Offset of `rect`'s origin inside the libass bitmap (non-zero only
        /// where the canvas clipped it).
        var skipX: Int
        var skipY: Int
        /// libass's 0xRRGGBBAA, AA = transparency.
        var color: UInt32
    }

    func composite(_ first: UnsafeMutablePointer<ASS_Image>?, canvasWidth: Int, canvasHeight: Int) -> [SubtitleImage] {
        let layers = Self.layers(first, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        guard !layers.isEmpty else { return [] }
        return Self.regions(layers).compactMap { region in
            Self.render(layers: region.members.map { layers[$0] }, in: region.rect)
        }
    }

    static func layers(_ first: UnsafeMutablePointer<ASS_Image>?, canvasWidth: Int, canvasHeight: Int) -> [Layer] {
        var layers: [Layer] = []
        var cursor = first
        while let image = cursor?.pointee {
            cursor = image.next
            // Fully transparent (AA = 0xFF) or empty: nothing to blend.
            guard image.w > 0, image.h > 0, image.color & 0xFF != 0xFF, let bitmap = image.bitmap else { continue }
            let x = Int(image.dst_x), y = Int(image.dst_y)
            let clipped = Rect(minX: max(0, x), minY: max(0, y),
                               maxX: min(canvasWidth, x + Int(image.w)), maxY: min(canvasHeight, y + Int(image.h)))
            guard clipped.width > 0, clipped.height > 0 else { continue }
            layers.append(Layer(rect: clipped, bitmap: UnsafePointer(bitmap), stride: Int(image.stride),
                                skipX: clipped.minX - x, skipY: clipped.minY - y, color: image.color))
        }
        return layers
    }

    /// Clusters of layer indices; members keep libass's back-to-front order.
    static func regions(_ layers: [Layer]) -> [(rect: Rect, members: [Int])] {
        var regions: [(rect: Rect, members: [Int])] = []
        for (index, layer) in layers.enumerated() {
            var rect = layer.rect
            var members = [index]
            // Absorb every region this layer bridges, until nothing more touches.
            var merged = true
            while merged {
                merged = false
                if let hit = regions.firstIndex(where: { $0.rect.touches(rect, within: mergeDistance) }) {
                    rect = rect.union(regions[hit].rect)
                    members = regions[hit].members + members
                    regions.remove(at: hit)
                    merged = true
                }
            }
            regions.append((rect, members.sorted()))
        }
        return regions
    }

    /// Source-over blend of every member, premultiplied BGRA.
    static func render(layers: [Layer], in region: Rect) -> SubtitleImage? {
        let width = region.width, height = region.height
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for layer in layers { blend(layer, into: base, bytesPerRow: bytesPerRow, origin: region) }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return SubtitleImage(image: image, frame: CGRect(x: region.minX, y: region.minY, width: width, height: height))
    }

    /// `x * y / 255`, rounded, for 0…255 operands, without a divide. Sums of
    /// two are clamped by the caller: both halves rounding up can reach 256,
    /// and `UInt8(256)` traps.
    @inline(__always)
    static func mul255(_ x: UInt32, _ y: UInt32) -> UInt32 {
        let t = x * y + 128
        return (t + (t >> 8)) >> 8
    }

    static func blend(_ layer: Layer, into base: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, origin: Rect) {
        let red = layer.color >> 24, green = (layer.color >> 16) & 0xFF, blue = (layer.color >> 8) & 0xFF
        let opacity = 255 - (layer.color & 0xFF)
        for row in 0..<layer.rect.height {
            let source = layer.bitmap + (row + layer.skipY) * layer.stride + layer.skipX
            var target = base + (layer.rect.minY - origin.minY + row) * bytesPerRow + (layer.rect.minX - origin.minX) * 4
            for column in 0..<layer.rect.width {
                let coverage = UInt32(source[column])
                if coverage != 0 {
                    let alpha = mul255(coverage, opacity)
                    let keep = 255 - alpha
                    target[0] = UInt8(min(255, mul255(blue, alpha) + mul255(UInt32(target[0]), keep)))
                    target[1] = UInt8(min(255, mul255(green, alpha) + mul255(UInt32(target[1]), keep)))
                    target[2] = UInt8(min(255, mul255(red, alpha) + mul255(UInt32(target[2]), keep)))
                    target[3] = UInt8(min(255, alpha + mul255(UInt32(target[3]), keep)))
                }
                target += 4
            }
        }
    }
}
