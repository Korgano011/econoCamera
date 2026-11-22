import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Builds a panorama from camera frames while the person turns slowly.
/// Each frame is lined up with the last kept frame using Vision; when the
/// view has moved far enough, the frame is kept. At the end the kept frames
/// are laid side by side and saved at the chosen resolution.
/// `add` is called on the capture queue; `finish` afterwards.
nonisolated final class PanoStitcher: @unchecked Sendable {
    struct Status: Sendable {
        var frames: Int
        var progress: Double   // 0…1 of the longest allowed pano
        var drift: Double      // how far up/down the view has wandered, 0…1
        var tooFast: Bool
    }

    enum PanoError: LocalizedError {
        case tooShort
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .tooShort: "Turn a little further before stopping — the panorama needs at least two views."
            case .failed(let message): "Couldn’t make the panorama: \(message)"
            }
        }
    }

    static let maxFrames = 24
    /// Frames are lined up at this height (enough detail for Vision).
    private let alignHeight: CGFloat = 360
    private let keepHeight: CGFloat

    private struct Kept {
        let image: CIImage      // scaled to keepHeight
        let offset: CGPoint     // where it goes, in keep-space
    }

    private var kept: [Kept] = []
    private var reference: CIImage?   // last kept frame at alignHeight
    private var referenceOffset = CGPoint.zero  // in align-space
    private var lastCheck = Date.distantPast
    private var lastShift: CGFloat = 0
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(resolution: Resolution) {
        keepHeight = max(alignHeight, CGFloat(resolution.lines) * 16 / 9)
    }

    private var keepScale: CGFloat { keepHeight / alignHeight }

    /// Feeds one camera frame. Returns new status when something changed.
    func add(_ frame: CIImage, force: Bool = false) -> Status? {
        let now = Date()
        guard force || now.timeIntervalSince(lastCheck) > 0.1 else { return nil }
        lastCheck = now

        let small = scaled(frame, toHeight: alignHeight)
        guard let reference else {
            keep(frame: frame, alignOffset: .zero)
            self.reference = small
            return status(tooFast: false)
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small)
        let handler = VNImageRequestHandler(ciImage: reference)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return status(tooFast: true)
        }
        let t = result.alignmentTransform
        let width = small.extent.width
        let tooFast = abs(t.tx) > width * 0.7
        // Keep a frame each time the view moves about a third of its width.
        if !tooFast, abs(t.tx) >= width * 0.33, kept.count < Self.maxFrames {
            let offset = CGPoint(x: referenceOffset.x + t.tx, y: referenceOffset.y + t.ty)
            keep(frame: frame, alignOffset: offset)
            self.reference = small
            referenceOffset = offset
        }
        lastShift = t.tx
        return status(tooFast: tooFast)
    }

    var isFull: Bool { kept.count >= Self.maxFrames }

    private func keep(frame: CIImage, alignOffset: CGPoint) {
        let image = scaled(frame, toHeight: keepHeight)
        // Render now so the camera buffer can be reused.
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        kept.append(Kept(image: CIImage(cgImage: cg),
                         offset: CGPoint(x: alignOffset.x * keepScale, y: alignOffset.y * keepScale)))
    }

    private func status(tooFast: Bool) -> Status {
        let xs = kept.map(\.offset.x)
        let span = (xs.max() ?? 0) - (xs.min() ?? 0)
        let frameWidth = kept.first?.image.extent.width ?? 1
        let ys = kept.map(\.offset.y)
        let drift = ((ys.max() ?? 0) - (ys.min() ?? 0)) / keepHeight
        return Status(frames: kept.count,
                      progress: min(1, Double(span / (frameWidth * 0.33 * CGFloat(Self.maxFrames - 1)))),
                      drift: Double(drift), tooFast: tooFast)
    }

    private func scaled(_ image: CIImage, toHeight height: CGFloat) -> CIImage {
        let s = height / image.extent.height
        let moved = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return moved.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    /// Lays out the kept frames and returns the finished panorama, with the
    /// shorter side (its height) at the chosen resolution.
    func finish(resolution: Resolution) throws -> CGImage {
        guard kept.count >= 2 else { throw PanoError.tooShort }
        // Frames are drawn in order with a soft edge so seams blend.
        var canvas = CIImage.empty()
        var union = CGRect.null
        var top = CGFloat.infinity, bottom = -CGFloat.infinity
        let movingRight = (kept.last!.offset.x - kept.first!.offset.x) >= 0
        for (index, frame) in kept.enumerated() {
            let placed = frame.image.transformed(by: CGAffineTransform(translationX: frame.offset.x, y: frame.offset.y))
            let rect = placed.extent
            union = union.union(rect)
            top = min(top, rect.maxY)
            bottom = max(bottom, rect.minY)
            var layer = placed
            if index > 0 {
                // Fade in the leading edge over 15% of the frame width.
                let fade = rect.width * 0.15
                let x0 = movingRight ? rect.minX : rect.maxX
                let x1 = movingRight ? rect.minX + fade : rect.maxX - fade
                let mask = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: x0, y: rect.midY),
                    "inputPoint1": CIVector(x: x1, y: rect.midY),
                    "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                ])?.outputImage?.cropped(to: rect)
                if let mask {
                    layer = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: mask,
                    ])
                }
            }
            canvas = layer.composited(over: canvas)
        }
        // Trim the ragged top and bottom left by up/down wobble.
        var crop = CGRect(x: union.minX, y: bottom, width: union.width, height: max(1, top - bottom))
        if crop.height < union.height * 0.5 { crop = union }
        canvas = canvas.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        // Shorter side → chosen lines; keep the width within encoder limits.
        var scale = CGFloat(resolution.lines) / min(crop.width, crop.height)
        scale = min(1, scale, 8192 / max(crop.width, crop.height))
        let output = canvas.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = CGRect(x: 0, y: 0, width: floor(output.extent.width), height: floor(output.extent.height))
        let background = CIImage(color: .black).cropped(to: rect)
        guard let cg = context.createCGImage(output.composited(over: background), from: rect) else {
            throw PanoError.failed("couldn’t draw the picture")
        }
        return cg
    }
}

nonisolated enum ImageFile {
    /// Saves a picture as a JPEG (small and opens everywhere).
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.72) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Loads a picture upright (EXIF orientation applied).
    static func load(_ url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Shrinks a picture so its shorter side is the chosen resolution.
    static func shrink(_ image: CIImage, to resolution: Resolution, context: CIContext) -> CGImage? {
        let extent = image.extent
        let size = resolution.outputSize(for: extent.size)
        let sx = size.width / extent.width, sy = size.height / extent.height
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: sy,
                kCIInputAspectRatioKey: sx / sy,
            ])
        return context.createCGImage(scaled, from: CGRect(origin: .zero, size: size))
    }
}
