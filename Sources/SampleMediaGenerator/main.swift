// Renders Driftwall's original sample wallpapers and app icon.
//
// Every frame is drawn procedurally with Core Graphics, so the included media is original work with no
// third-party licensing. All motion is periodic over the clip length, so each video loops seamlessly.
//
// Usage: SampleMediaGenerator <output-directory> [--force] [--seconds N] [--width W --height H]

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var output: URL
    var force = false
    var seconds = 12
    var width = 1920
    var height = 1080
    var fps: Int32 = 30
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first, !first.hasPrefix("--") else {
        FileHandle.standardError.write(Data("usage: SampleMediaGenerator <output-dir> [--force] [--seconds N] [--width W --height H]\n".utf8))
        exit(2)
    }
    var options = Options(output: URL(fileURLWithPath: first, isDirectory: true))
    args.removeFirst()
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--force": options.force = true
        case "--seconds": options.seconds = Int(args.removeFirst()) ?? options.seconds
        case "--width": options.width = Int(args.removeFirst()) ?? options.width
        case "--height": options.height = Int(args.removeFirst()) ?? options.height
        default: break
        }
    }
    return options
}

// MARK: - Drawing helpers

let tau = Double.pi * 2

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) }
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else { return }
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: UInt32, alpha: CGFloat) {
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: [rgb(color, alpha), rgb(color, alpha * 0.45), rgb(color, 0)] as CFArray, locations: [0, 0.45, 1]) else { return }
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// Deterministic pseudo-random values so every render is identical.
struct Rand {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

typealias Painter = (_ ctx: CGContext, _ size: CGSize, _ t: Double) -> Void

// MARK: - Styles (t runs 0 ..< 1 over the clip; all motion uses whole-number frequencies of t)

func auroraDrift(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    linearGradient(ctx, [rgb(0x020814), rgb(0x061A2B), rgb(0x0B2A3A)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: s.height))
    let bands: [(UInt32, Double, Double, Double)] = [(0x2EF2B0, 0.62, 1, 0.0), (0x2BB6F0, 0.55, 2, 1.3), (0x9B6CFF, 0.70, 1, 2.6), (0x46F59A, 0.48, 3, 4.1)]
    ctx.setBlendMode(.screen)
    for (color, baseY, k, phase) in bands {
        for layer in 0..<10 {
            let path = CGMutablePath()
            let thickness = s.height * (0.05 + 0.012 * Double(layer))
            let steps = 64
            var top: [CGPoint] = []
            for i in 0...steps {
                let x = s.width * Double(i) / Double(steps)
                let u = x / s.width
                let y = s.height * baseY
                    + sin(u * 5.2 + tau * k * t + phase) * s.height * 0.07
                    + sin(u * 11.0 - tau * t + phase * 2) * s.height * 0.025
                top.append(CGPoint(x: x, y: y))
            }
            path.move(to: top[0])
            top.dropFirst().forEach { path.addLine(to: $0) }
            for point in top.reversed() { path.addLine(to: CGPoint(x: point.x, y: point.y - thickness)) }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(rgb(color, 0.035))
            ctx.fillPath()
        }
    }
    ctx.setBlendMode(.normal)
    var rand = Rand(state: 7)
    for _ in 0..<160 {
        let x = rand.next() * s.width, y = rand.next() * s.height * 0.55
        let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(tau * (t * Double(1 + Int(rand.next() * 3))) + rand.next() * tau))
        ctx.setFillColor(rgb(0xFFFFFF, CGFloat(0.55 * twinkle)))
        let r = 0.6 + rand.next() * 1.4
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}

func emberDusk(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    linearGradient(ctx, [rgb(0x1B0B2E), rgb(0x5A1E4A), rgb(0xC4502E), rgb(0xF2A65A)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: s.height))
    ctx.setBlendMode(.screen)
    let blobs: [(UInt32, Double, Double, Int, Int, Double)] = [
        (0xFF7A3D, 0.30, 0.65, 1, 2, 0.45), (0xFFB65C, 0.70, 0.75, 2, 1, 0.38), (0xE0457B, 0.55, 0.40, 1, 1, 0.50),
        (0x8E3CC8, 0.20, 0.25, 2, 3, 0.42), (0xFFD08A, 0.85, 0.30, 1, 2, 0.30),
    ]
    for (i, (color, cx, cy, kx, ky, radius)) in blobs.enumerated() {
        let phase = Double(i) * 1.7
        let center = CGPoint(x: s.width * (cx + 0.12 * sin(tau * Double(kx) * t + phase)),
                             y: s.height * (cy + 0.10 * cos(tau * Double(ky) * t + phase)))
        glow(ctx, center: center, radius: s.width * radius, color: color, alpha: 0.55)
    }
    ctx.setBlendMode(.normal)
}

func deepTide(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    linearGradient(ctx, [rgb(0x01060F), rgb(0x04203D), rgb(0x0A4C78)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: s.height))
    glow(ctx, center: CGPoint(x: s.width * 0.5, y: s.height * 0.95), radius: s.width * 0.6, color: 0x7FD6FF, alpha: 0.35)
    let layers = 7
    for layer in 0..<layers {
        let depth = Double(layer) / Double(layers - 1)
        let baseline = s.height * (0.72 - depth * 0.62)
        let amplitude = s.height * (0.035 + depth * 0.03)
        let k = Double(layer % 3 + 1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        let steps = 96
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let y = baseline + sin(u * tau * (1.5 + depth) + tau * k * t * (layer % 2 == 0 ? 1 : -1)) * amplitude
                + sin(u * tau * 4 + tau * t + Double(layer)) * amplitude * 0.25
            path.addLine(to: CGPoint(x: u * s.width, y: y))
        }
        path.addLine(to: CGPoint(x: s.width, y: 0))
        path.closeSubpath()
        let shade = 0.25 + 0.6 * (1 - depth)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.10 + 0.18 * shade, blue: 0.22 + 0.35 * shade, alpha: 0.55))
        ctx.fillPath()
    }
}

func nebulaBloom(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    ctx.setFillColor(rgb(0x05030C))
    ctx.fill(CGRect(origin: .zero, size: s))
    var rand = Rand(state: 42)
    for _ in 0..<420 {
        let x = rand.next() * s.width, y = rand.next() * s.height
        let speed = Double(1 + Int(rand.next() * 3))
        let twinkle = 0.25 + 0.75 * (0.5 + 0.5 * sin(tau * speed * t + rand.next() * tau))
        let r = 0.5 + rand.next() * 1.6
        ctx.setFillColor(rgb(0xDDE6FF, CGFloat(0.8 * twinkle)))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    ctx.setBlendMode(.screen)
    let clouds: [(UInt32, Double, Double, Double)] = [(0xC03CFF, 0.40, 0.55, 0.42), (0x3C6CFF, 0.62, 0.45, 0.40), (0xFF4FA3, 0.52, 0.62, 0.28), (0x35E0FF, 0.35, 0.38, 0.22)]
    for (i, (color, cx, cy, r)) in clouds.enumerated() {
        let pulse = 1 + 0.08 * sin(tau * t + Double(i))
        let center = CGPoint(x: s.width * (cx + 0.04 * sin(tau * t + Double(i) * 2)), y: s.height * (cy + 0.04 * cos(tau * t + Double(i))))
        glow(ctx, center: center, radius: s.width * r * pulse, color: color, alpha: 0.42)
    }
    ctx.setBlendMode(.normal)
}

func silkMono(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    linearGradient(ctx, [rgb(0x0C0C0E), rgb(0x1C1C20), rgb(0x0C0C0E)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: s.width, y: s.height))
    ctx.setLineWidth(1.4)
    let lines = 90
    for line in 0..<lines {
        let v = Double(line) / Double(lines)
        let path = CGMutablePath()
        let steps = 120
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let y = s.height * (0.15 + 0.7 * v)
                + sin(u * tau * 1.2 + v * 3 + tau * t) * s.height * 0.12
                + sin(u * tau * 2.7 - v * 5 + tau * 2 * t) * s.height * 0.04
            let point = CGPoint(x: u * s.width, y: y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let brightness = 0.25 + 0.55 * (0.5 + 0.5 * sin(v * tau * 2 + tau * t))
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: CGFloat(brightness), alpha: 0.35))
        ctx.strokePath()
    }
}

func citrusHaze(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    linearGradient(ctx, [rgb(0xFFF6E5), rgb(0xFDE7C8)], from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width, y: 0))
    ctx.setBlendMode(.multiply)
    let blobs: [(UInt32, Double, Double, Double)] = [(0xFFD54F, 0.25, 0.65, 0.40), (0xB8E986, 0.70, 0.70, 0.36), (0xFFAB91, 0.55, 0.30, 0.42), (0x80DEEA, 0.15, 0.20, 0.30), (0xF8BBD0, 0.88, 0.25, 0.30)]
    for (i, (color, cx, cy, r)) in blobs.enumerated() {
        let center = CGPoint(x: s.width * (cx + 0.08 * sin(tau * t * Double(1 + i % 2) + Double(i))),
                             y: s.height * (cy + 0.08 * cos(tau * t + Double(i) * 1.3)))
        glow(ctx, center: center, radius: s.width * r, color: color, alpha: 0.85)
    }
    ctx.setBlendMode(.normal)
}

func neonGrid(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    let horizon = s.height * 0.45
    linearGradient(ctx, [rgb(0x0D0221), rgb(0x261447), rgb(0x541A5E)], from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: horizon))
    ctx.setFillColor(rgb(0x0D0221))
    ctx.fill(CGRect(x: 0, y: 0, width: s.width, height: horizon))
    // Sun with horizontal cut lines.
    let sunCenter = CGPoint(x: s.width / 2, y: horizon + s.height * 0.16)
    let sunRadius = s.height * 0.2
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
    ctx.clip()
    linearGradient(ctx, [rgb(0xFF2E88), rgb(0xFFB347), rgb(0xFFE66D)], from: CGPoint(x: 0, y: sunCenter.y - sunRadius), to: CGPoint(x: 0, y: sunCenter.y + sunRadius))
    ctx.setFillColor(rgb(0x261447))
    for i in 0..<6 {
        let y = sunCenter.y - sunRadius + Double(i) * sunRadius * 0.16 + (t * sunRadius * 0.16)
        ctx.fill(CGRect(x: sunCenter.x - sunRadius, y: y, width: sunRadius * 2, height: sunRadius * 0.03 * Double(6 - i)))
    }
    ctx.restoreGState()
    glow(ctx, center: sunCenter, radius: sunRadius * 2.4, color: 0xFF2E88, alpha: 0.18)
    // Perspective grid scrolling toward the viewer; one row spacing per loop keeps it seamless.
    ctx.setStrokeColor(rgb(0x2DE2E6, 0.75))
    ctx.setLineWidth(2)
    let vanishing = CGPoint(x: s.width / 2, y: horizon)
    for i in -16...16 {
        ctx.move(to: vanishing)
        ctx.addLine(to: CGPoint(x: s.width / 2 + Double(i) * s.width * 0.12, y: 0))
    }
    ctx.strokePath()
    let rows = 14
    for row in 0..<rows {
        let z = (Double(row) + 1 - t) / Double(rows)
        let y = horizon * pow(z, 2.2)
        ctx.setStrokeColor(rgb(0x2DE2E6, CGFloat(0.25 + 0.6 * (1 - z))))
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addLine(to: CGPoint(x: s.width, y: y))
        ctx.strokePath()
    }
}

func rainLights(_ ctx: CGContext, _ s: CGSize, _ t: Double) {
    linearGradient(ctx, [rgb(0x03060D), rgb(0x0B1A2E), rgb(0x132A40)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: s.width, y: s.height))
    var rand = Rand(state: 2024)
    let palette: [UInt32] = [0xFFC46B, 0xFF7E67, 0x7AD7F0, 0xB794F6, 0xFFE3A3]
    ctx.setBlendMode(.screen)
    for _ in 0..<70 {
        let x0 = rand.next(), y0 = rand.next()
        let laps = Double(1 + Int(rand.next() * 2))
        let radius = s.height * (0.02 + rand.next() * 0.07)
        let color = palette[Int(rand.next() * Double(palette.count)) % palette.count]
        let alpha = 0.18 + rand.next() * 0.35
        var y = (y0 - laps * t).truncatingRemainder(dividingBy: 1)
        if y < 0 { y += 1 }
        let span = s.height + radius * 4
        let center = CGPoint(x: s.width * x0 + sin(tau * t + x0 * 10) * s.width * 0.01, y: y * span - radius * 2)
        glow(ctx, center: center, radius: radius, color: color, alpha: CGFloat(alpha))
    }
    ctx.setBlendMode(.normal)
}

let styles: [(file: String, painter: Painter)] = [
    ("aurora-drift.mov", auroraDrift),
    ("ember-dusk.mov", emberDusk),
    ("deep-tide.mov", deepTide),
    ("nebula-bloom.mov", nebulaBloom),
    ("silk-mono.mov", silkMono),
    ("citrus-haze.mov", citrusHaze),
    ("neon-grid.mov", neonGrid),
    ("rain-lights.mov", rainLights),
]

// MARK: - Encoding

func render(_ painter: Painter, to url: URL, options: Options) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: options.width,
        AVVideoHeightKey: options.height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 3_500_000,
            AVVideoExpectedSourceFrameRateKey: Int(options.fps),
            AVVideoMaxKeyFrameIntervalKey: Int(options.fps) * 2,
        ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: options.width,
        kCVPixelBufferHeightKey as String: options.height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "gen", code: 1) }
    writer.startSession(atSourceTime: .zero)

    let frameCount = options.seconds * Int(options.fps)
    let size = CGSize(width: options.width, height: options.height)
    for frame in 0..<frameCount {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "gen", code: 2) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else { throw NSError(domain: "gen", code: 3) }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: options.width, height: options.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw NSError(domain: "gen", code: 4)
        }
        ctx.setShouldAntialias(true)
        painter(ctx, size, Double(frame) / Double(frameCount))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: options.fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "gen", code: 5) }
}

func renderIcon(to url: URL) throws {
    let side = 1024
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let size = CGSize(width: side, height: side)
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x061A2B))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    auroraDrift(ctx, size, 0.15)
    // Three stacked "drifting" wave strokes as the mark.
    ctx.setLineCap(.round)
    for (i, color) in [UInt32(0xF2A65A), 0xFFFFFF, 0x2EF2B0].enumerated() {
        let path = CGMutablePath()
        let y0 = 380 + Double(i) * 130
        for step in 0...60 {
            let u = Double(step) / 60
            let point = CGPoint(x: 210 + u * 604, y: y0 + sin(u * tau * 1.25 + Double(i) * 0.8) * 55)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(color, i == 1 ? 0.95 : 0.85))
        ctx.setLineWidth(i == 1 ? 46 : 34)
        ctx.strokePath()
    }
    ctx.restoreGState()
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// MARK: - Main

let options = parseOptions()
let samples = options.output.appendingPathComponent("Samples", isDirectory: true)
try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)

let iconURL = options.output.appendingPathComponent("AppIcon-1024.png")
if options.force || !FileManager.default.fileExists(atPath: iconURL.path) {
    try renderIcon(to: iconURL)
    print("Rendered app icon")
}

for style in styles {
    let url = samples.appendingPathComponent(style.file)
    if !options.force, FileManager.default.fileExists(atPath: url.path) {
        print("✓ \(style.file) (cached)")
        continue
    }
    let start = Date()
    try render(style.painter, to: url, options: options)
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    print(String(format: "Rendered %@ in %.1fs (%.1f MB)", style.file, Date().timeIntervalSince(start), Double(size) / 1_048_576))
}
