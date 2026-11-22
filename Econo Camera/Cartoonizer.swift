import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// How a picture is drawn as a cartoon.
nonisolated enum CartoonStyle: String, CaseIterable, Identifiable, Sendable {
    case original, blackAndWhite, toon, comic, sketch, popArt, neon, oldTimey, crayon

    var id: String { rawValue }

    /// Styles that keep the real picture (only its color may change).
    var keepsPhoto: Bool { self == .original || self == .blackAndWhite }

    var name: String {
        switch self {
        case .original: "Original Picture"
        case .toon: "Toon"
        case .comic: "Comic Book"
        case .sketch: "Pencil Sketch"
        case .popArt: "Pop Art"
        case .neon: "Neon Glow"
        case .oldTimey: "Old-Time Cartoon"
        case .crayon: "Crayon"
        case .blackAndWhite: "Black & White"
        }
    }
}

/// How the cartoon moves.
nonisolated enum CartoonAnimation: String, CaseIterable, Identifiable, Sendable {
    case lineBoil, bounce, wiggle, zoom, drawOn, colorCycle, pan, still

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lineBoil: "Wobbly Lines"
        case .bounce: "Bounce"
        case .wiggle: "Wiggle"
        case .zoom: "Zoom In"
        case .drawOn: "Draw It On"
        case .colorCycle: "Rainbow"
        case .pan: "Pan Across"
        case .still: "Still Picture"
        }
    }

    var symbol: String {
        switch self {
        case .lineBoil: "scribble.variable"
        case .bounce: "figure.jumprope"
        case .wiggle: "water.waves"
        case .zoom: "plus.magnifyingglass"
        case .drawOn: "pencil.and.scribble"
        case .colorCycle: "rainbow"
        case .pan: "arrow.left.and.right"
        case .still: "photo"
        }
    }
}

/// Turns a picture into a cartoon, as a still or a short MP4 animation.
nonisolated enum Cartoonizer {
    enum CartoonError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): "Couldn’t make the cartoon: \(message)" }
        }
    }

    /// Shared context: Core Image contexts are expensive to make.
    nonisolated(unsafe) static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    struct Layers {
        var fill: CIImage
        /// Dark outlines on a clear background, drawn over the fill (some styles have none).
        var lines: CIImage?
        var paper: CIColor
    }

    // MARK: Styles

    /// Brings a picture to a working size (shorter side `short`), origin at 0,0.
    static func prepare(_ image: CIImage, short: CGFloat) -> CIImage {
        let e = image.extent
        let s = min(1.5, short / min(e.width, e.height))
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            .cropped(to: CGRect(x: 0, y: 0, width: floor(e.width * s), height: floor(e.height * s)))
    }

    static func layers(for source: CIImage, style: CartoonStyle) -> Layers {
        let rect = source.extent
        let short = min(rect.width, rect.height)
        let clamped = source.clampedToExtent()

        func smooth(_ image: CIImage, _ radius: CGFloat) -> CIImage {
            image.clampedToExtent()
                .applyingFilter("CIMedianFilter")
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.04, "inputSharpness": 0.2])
                .applyingGaussianBlur(sigma: radius)
                .cropped(to: rect)
        }
        func posterize(_ image: CIImage, _ levels: Int) -> CIImage {
            image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
        }
        func color(_ image: CIImage, saturation: Double, contrast: Double = 1, brightness: Double = 0) -> CIImage {
            image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation, kCIInputContrastKey: contrast, kCIInputBrightnessKey: brightness,
            ])
        }
        func outlines(edge: Double = 1, threshold: Double = 0.1, thicker: CGFloat = 0) -> CIImage {
            var lines = clamped
                .applyingFilter("CILineOverlay", parameters: [
                    "inputNRNoiseLevel": 0.06,
                    "inputNRSharpness": 0.7,
                    "inputEdgeIntensity": edge,
                    "inputThreshold": threshold,
                    "inputContrast": 60,
                ])
            if thicker > 0 {
                // Spread the dark lines by growing their alpha.
                lines = lines.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: thicker])
            }
            return lines.cropped(to: rect)
        }

        let white = CIColor(red: 1, green: 1, blue: 1)
        switch style {
        case .original:
            // The picture as it is — only the animation is added.
            return Layers(fill: source, lines: nil, paper: CIColor(red: 0, green: 0, blue: 0))
        case .toon:
            let fill = color(posterize(smooth(source, short / 300), 7), saturation: 1.35, contrast: 1.05)
            return Layers(fill: fill, lines: outlines(edge: 1, threshold: 0.12, thicker: short / 400), paper: white)
        case .comic:
            let fill = clamped.applyingFilter("CIComicEffect").cropped(to: rect)
            return Layers(fill: fill, lines: nil, paper: white)
        case .sketch:
            let shade = color(smooth(source, short / 250), saturation: 0, contrast: 0.6, brightness: 0.35)
            let paper = CIColor(red: 0.98, green: 0.97, blue: 0.93)
            let lines = outlines(edge: 1.5, threshold: 0.08)
            let tint = shade.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
            ])
            return Layers(fill: tint.composited(over: CIImage(color: paper).cropped(to: rect)), lines: lines, paper: paper)
        case .popArt:
            let fill = color(posterize(smooth(source, short / 200), 3), saturation: 2.4, contrast: 1.3)
            return Layers(fill: fill, lines: outlines(edge: 1.3, threshold: 0.1, thicker: short / 250), paper: white)
        case .neon:
            let edges = clamped.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 8]).cropped(to: rect)
            let bright = color(edges, saturation: 2.5, contrast: 1.4, brightness: 0.05)
            let glow = bright.clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: short / 60, kCIInputIntensityKey: 1.2,
            ]).cropped(to: rect)
            return Layers(fill: glow, lines: nil, paper: CIColor(red: 0, green: 0, blue: 0))
        case .oldTimey:
            let base = posterize(smooth(source, short / 300), 5)
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
            let fill = base.clampedToExtent()
                .applyingFilter("CIVignette", parameters: [kCIInputRadiusKey: 1.6, kCIInputIntensityKey: 1.1])
                .cropped(to: rect)
            return Layers(fill: fill, lines: outlines(edge: 1.2, threshold: 0.1, thicker: short / 500),
                          paper: CIColor(red: 0.93, green: 0.88, blue: 0.75))
        case .crayon:
            let paper = CIColor(red: 1, green: 0.99, blue: 0.96)
            let colors = color(posterize(smooth(source, short / 150), 6), saturation: 1.6, brightness: 0.08)
            // Rough, grainy strokes: break up the color with paper-colored noise.
            let grain = CIFilter.randomGenerator().outputImage!
                .transformed(by: CGAffineTransform(scaleX: 1.5, y: 6))
                .cropped(to: rect)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: paper.red, y: paper.green, z: paper.blue, w: -0.12),
                ])
                .cropped(to: rect)
            let fill = grain.composited(over: colors).cropped(to: rect)
            return Layers(fill: fill, lines: outlines(edge: 1, threshold: 0.12), paper: paper)
        case .blackAndWhite:
            // The real picture in classic black and white (no cartoon effect).
            let fill = source.applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
                .cropped(to: rect)
            return Layers(fill: fill, lines: nil, paper: CIColor(red: 0, green: 0, blue: 0))
        }
    }

    static func flatten(_ layers: Layers) -> CIImage {
        let rect = layers.fill.extent
        var image = layers.fill
        if let lines = layers.lines { image = lines.composited(over: image) }
        return image.composited(over: CIImage(color: layers.paper).cropped(to: rect))
    }

    /// A quick preview picture (for style buttons).
    static func preview(_ source: CIImage, style: CartoonStyle, short: CGFloat = 160) -> CGImage? {
        let prepared = prepare(source, short: short)
        let image = flatten(layers(for: prepared, style: style))
        return context.createCGImage(image, from: prepared.extent)
    }

    /// The finished still cartoon at the chosen resolution.
    static func still(_ source: CIImage, style: CartoonStyle, resolution: Resolution) -> CGImage? {
        let prepared = prepare(source, short: max(480, CGFloat(resolution.lines)))
        let image = flatten(layers(for: prepared, style: style))
        return ImageFile.shrink(image, to: resolution, context: context)
    }

    // MARK: Animation

    struct Movie: Sendable {
        var style: CartoonStyle
        var animation: CartoonAnimation
        var resolution: Resolution
        var seconds: Double
        var codec: VideoCodec
        var fps: Int = 15
    }

    /// Renders the animated cartoon to an MP4 at `destination`.
    static func animate(_ source: CIImage, movie: Movie, to destination: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await render(source, movie: movie, to: destination, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func render(_ source: CIImage, movie: Movie, to destination: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let isWide = source.extent.width > source.extent.height * 2.2
        let workShort = max(480, CGFloat(movie.resolution.lines))
        let prepared = prepare(source, short: workShort)
        let picture = prepared.extent
        let layers = layers(for: prepared, style: movie.style)
        let flat = flatten(layers)

        // The movie's frame (in work space): a pan shows a 16:9 window
        // moving across; everything else shows the whole picture (a very
        // wide panorama is shown as a 16:9 window too).
        let panning = movie.animation == .pan || isWide
        var frame = picture
        if panning {
            if picture.width >= picture.height {
                let h = picture.height
                frame = CGRect(x: 0, y: 0, width: min(picture.width, h * 16 / 9), height: h)
            } else {
                let w = picture.width
                frame = CGRect(x: 0, y: 0, width: w, height: min(picture.height, w * 16 / 9))
            }
        }
        let outSize = movie.resolution.outputSize(for: frame.size)
        let outScale = outSize.width / frame.width

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: movie.resolution.videoBitRate(codec: movie.codec),
            AVVideoExpectedSourceFrameRateKey: movie.fps,
            AVVideoMaxKeyFrameIntervalKey: movie.fps * 2,
        ]
        if movie.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: movie.codec.avCodec,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        guard writer.canAdd(input) else { throw CartoonError.failed("this size isn’t supported") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outSize.width),
            kCVPixelBufferHeightKey as String: Int(outSize.height),
        ])
        guard writer.startWriting() else {
            throw CartoonError.failed(writer.error?.localizedDescription ?? "couldn’t start")
        }
        writer.startSession(atSourceTime: .zero)

        let count = max(1, Int(movie.seconds * Double(movie.fps)))
        // Draw It On with the original picture: pencil lines first, then the photo fades in.
        let drawOnLines = layers.lines ?? (movie.style.keepsPhoto && movie.animation == .drawOn
            ? Self.layers(for: prepared, style: .sketch).lines : nil)
        let keepsPhoto = movie.style.keepsPhoto
        let paper = CIImage(color: keepsPhoto && movie.animation == .drawOn ? CIColor(red: 1, green: 1, blue: 1) : layers.paper)
        var random = SeededRandom(seed: 7)
        var jitter = (dx: CGFloat(0), dy: CGFloat(0), angle: CGFloat(0))
        let unit = picture.height / 300   // ~1 px at 300 px tall

        for index in 0..<count {
            try Task.checkCancellation()
            let t = Double(index) / Double(max(1, count - 1))
            var image: CIImage
            switch movie.animation {
            case .still:
                image = flat
            case .lineBoil:
                // A new hand-drawn wobble every 3 frames.
                if index % 3 == 0 {
                    jitter = (CGFloat(random.next(-1.4, 1.4)) * unit, CGFloat(random.next(-1.4, 1.4)) * unit,
                              CGFloat(random.next(-0.004, 0.004)))
                }
                let wobble = CGAffineTransform(translationX: picture.midX, y: picture.midY)
                    .rotated(by: jitter.angle)
                    .translatedBy(x: -picture.midX + jitter.dx, y: -picture.midY + jitter.dy)
                if let lines = layers.lines {
                    image = lines.transformed(by: wobble).composited(over: layers.fill)
                } else {
                    image = layers.fill.clampedToExtent()
                        .applyingFilter("CIBumpDistortion", parameters: [
                            kCIInputCenterKey: CIVector(x: picture.midX + jitter.dx * 30, y: picture.midY + jitter.dy * 30),
                            kCIInputRadiusKey: picture.width * 0.6,
                            kCIInputScaleKey: jitter.angle * 25,
                        ])
                        .transformed(by: CGAffineTransform(translationX: jitter.dx, y: jitter.dy))
                }
            case .bounce:
                // Squash and stretch, hopping three times.
                let phase = t * 3
                let hop = abs(sin(phase * .pi))
                let squash = 1 - 0.12 * pow(1 - hop, 6)
                let stretch = 1 + 0.06 * hop
                let sy = squash * stretch
                let sx = 1 / sqrt(sy)
                let lift = hop * picture.height * 0.08
                let shrink = 0.86
                image = flat.transformed(by: CGAffineTransform(translationX: picture.midX, y: picture.height * 0.04 + lift)
                    .scaledBy(x: sx * shrink, y: sy * shrink)
                    .translatedBy(x: -picture.midX, y: 0))
            case .wiggle:
                let angle = sin(t * .pi * 6) * 0.07
                let zoom = 1.12 + 0.03 * sin(t * .pi * 4)
                image = flat.clampedToExtent().transformed(by: CGAffineTransform(translationX: picture.midX, y: picture.midY)
                    .rotated(by: angle).scaledBy(x: zoom, y: zoom)
                    .translatedBy(x: -picture.midX, y: -picture.midY))
            case .zoom:
                let ease = t * t * (3 - 2 * t)
                let zoom = 1 + 0.45 * ease
                image = flat.clampedToExtent().transformed(by: CGAffineTransform(translationX: picture.midX, y: picture.midY)
                    .scaledBy(x: zoom, y: zoom)
                    .translatedBy(x: -picture.midX, y: -picture.midY))
            case .drawOn:
                // First half: lines draw across. Second half: color fills in.
                let lines = drawOnLines ?? flat.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                    .applyingFilter("CIColorPosterize", parameters: ["inputLevels": 2])
                let reveal = min(1, t / 0.5)
                let edge = picture.minX + picture.width * reveal * 1.1
                let mask = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: edge - picture.width * 0.08, y: 0),
                    "inputPoint1": CIVector(x: edge, y: 0),
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                ])!.outputImage!.cropped(to: picture)
                let drawn = lines.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
                ])
                let fillAmount = max(0, (t - 0.5) / 0.45)
                let fill = layers.fill.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(1, fillAmount)),
                ])
                if keepsPhoto {
                    // The pencil lines fade away as the real picture appears.
                    let fading = drawn.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - min(1, fillAmount)),
                    ])
                    image = fading.composited(over: fill)
                } else {
                    image = (layers.lines == nil && fillAmount >= 1 ? flat : drawn.composited(over: fill))
                }
            case .colorCycle:
                if movie.style == .blackAndWhite {
                    // Gray has no hue to turn, so tint it through the rainbow.
                    let tint = UIColorLike.hue(t)
                    image = flat.applyingFilter("CIColorMonochrome", parameters: [
                        kCIInputColorKey: CIColor(red: tint.r, green: tint.g, blue: tint.b),
                        kCIInputIntensityKey: 0.55,
                    ])
                } else {
                    image = flat.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: t * 2 * .pi])
                }
            case .pan:
                image = flat
            }

            // Pick the window into the picture for this frame.
            var window = frame
            if panning {
                let ease = t * t * (3 - 2 * t)
                if picture.width >= picture.height {
                    window.origin.x = (picture.width - frame.width) * ease
                } else {
                    window.origin.y = (picture.height - frame.height) * (1 - ease)
                }
            }
            let shown = image.composited(over: paper)
                .cropped(to: window)
                .transformed(by: CGAffineTransform(translationX: -window.minX, y: -window.minY)
                    .concatenating(CGAffineTransform(scaleX: outScale, y: outScale)))

            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw CartoonError.failed("no frame buffers") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CartoonError.failed("no frame buffer") }
            context.render(shown, to: buffer, bounds: CGRect(origin: .zero, size: outSize),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(movie.fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw CartoonError.failed(writer.error?.localizedDescription ?? "couldn’t write a frame")
            }
            progress(Double(index + 1) / Double(count))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(movie.fps)))
        await writer.finishWriting()
        if writer.status != .completed {
            throw CartoonError.failed(writer.error?.localizedDescription ?? "couldn’t finish")
        }
    }
}

/// A bright color at position 0…1 around the color wheel.
nonisolated enum UIColorLike {
    static func hue(_ h: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let x = (h.truncatingRemainder(dividingBy: 1)) * 6
        let f = x - floor(x)
        switch Int(x) {
        case 0: return (1, f, 0)
        case 1: return (1 - f, 1, 0)
        case 2: return (0, 1, f)
        case 3: return (0, 1 - f, 1)
        case 4: return (f, 0, 1)
        default: return (1, 0, 1 - f)
        }
    }
}

/// Repeatable random numbers so the same cartoon wobbles the same way.
nonisolated struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(_ low: Double, _ high: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return low + (high - low) * unit
    }
}
