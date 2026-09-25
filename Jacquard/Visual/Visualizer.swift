import MetalKit
import SwiftUI
import simd

// The wash behind the score: the finished mix, and the selected channel's dry share of
// it, drawn as two oscilloscope traces. Ported from Assets/Jacquard/Visual/Visualizer.cs.
//
// It is the one part of the app nothing else is allowed to depend on. It draws the synth
// rather than the sequence, reads the scope and nothing else, and may be removed outright.
//
// It is handed the synth and asks it for nothing but the scope. The app's own frame is
// driven elsewhere (JacquardEngine's display link), so this can be taken out without
// anything else noticing.

struct VisualizerVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    // How much of the scope one sweep shows, in seconds.
    var window: Float = 0.03

    init?(view: MTKView, engine: JacquardEngine) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: VisualizerShader.source, options: nil)
        else { return nil }

        self.engine = engine
        self.queue = queue

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "visualizerVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "visualizerFragment")

        // Behind everything and in front of nothing: laid over whatever was cleared to,
        // alpha blended, no depth.
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }

        self.pipeline = pipeline

        let vertexBytes = VisualizerRenderer.maxColumns * 2 * 4 * MemoryLayout<VisualizerVertex>.stride
        let indexCount = VisualizerRenderer.maxColumns * 2 * 6

        vertexBuffers = (0..<VisualizerRenderer.inFlight).compactMap { _ in
            device.makeBuffer(length: vertexBytes, options: .storageModeShared)
        }

        var indices: [UInt16] = []
        indices.reserveCapacity(indexCount)
        for quad in 0..<(VisualizerRenderer.maxColumns * 2) {
            let i = UInt16(quad * 4)
            indices += [i, i + 1, i + 2, i, i + 2, i + 3]
        }
        indexBuffer = device.makeBuffer(bytes: indices,
                                        length: indices.count * MemoryLayout<UInt16>.stride,
                                        options: .storageModeShared)!

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        inFlight.wait()

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            inFlight.signal()
            return
        }

        let size = view.drawableSize
        let quads = build(width: Float(size.width), height: Float(max(size.height, 1)))

        if quads > 0 {
            var uniforms = Float(size.width / max(size.height, 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffers[frame], offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Float>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: quads * 6,
                                          indexType: .uint16, indexBuffer: indexBuffer,
                                          indexBufferOffset: 0)
        }

        encoder.endEncoding()

        let semaphore = inFlight
        buffer.addCompletedHandler { _ in semaphore.signal() }
        buffer.present(drawable)
        buffer.commit()

        frame = (frame + 1) % VisualizerRenderer.inFlight
    }

    // MARK: Building the traces

    // Writes both traces into this frame's vertex buffer and answers how many quads.
    private func build(width: Float, height: Float) -> Int {
        guard let synth = engine.synth, let scope = synth.scope else { return 0 }

        // Units of the half height, the way the orthographic camera measured them.
        let halfHeight: Float = 1
        let halfWidth = width / height
        let pixel = halfHeight * 2 / height

        let vertices = vertexBuffers[frame].contents()
            .bindMemory(to: VisualizerVertex.self, capacity: VisualizerRenderer.maxColumns * 8)
        var count = 0

        let span = min(max(Int(window * Float(synth.sampleRate)), 64), scope.length / 2)
        let start = trigger(scope, span)

        buildTrace(scope, tapped: false, start, span, VisualizerRenderer.traceColor,
                   halfWidth, halfHeight, pixel, vertices, &count)

        if scope.watch != 0 {
            buildTrace(scope, tapped: true, start, span, VisualizerRenderer.channelColor,
                       halfWidth, halfHeight, pixel, vertices, &count)
        }

        return count / 4
    }

    // One ribbon a column wide per stretch of samples, each column the sample of
    // greatest magnitude in its stretch, faded out at both ends.
    private func buildTrace(_ scope: FmSynthScope, tapped: Bool, _ start: Int, _ span: Int,
                            _ color: SIMD4<Float>, _ halfWidth: Float, _ halfHeight: Float,
                            _ pixel: Float, _ vertices: UnsafeMutablePointer<VisualizerVertex>,
                            _ count: inout Int) {
        let columns = min(max(Int((halfWidth * 2 / pixel / 3).rounded()), 64),
                          VisualizerRenderer.maxColumns)
        let thickness = pixel * 1.5
        let height = halfHeight * VisualizerRenderer.traceHeight

        var previous = SIMD2<Float>(0, 0)

        for column in 0..<columns {
            let from = start + column * span / columns
            let to = start + (column + 1) * span / columns

            var value: Float = 0
            var i = from
            repeat {
                let sample = tapped ? scope.tapAt(i) : scope.at(i)
                if abs(sample) > abs(value) { value = sample }
                i += 1
            } while i < to

            let x = -halfWidth + (halfWidth * 2) * (Float(column) / Float(columns - 1))
            // The mesh's y runs up, as the camera's did.
            let point = SIMD2<Float>(x, min(max(value, -1), 1) * height)

            if column > 0 {
                ribbon(previous, point, thickness, fade(color, column, columns), vertices, &count)
            }

            previous = point
        }
    }

    // Walks back from the newest sample to the last rising zero crossing, so the trace
    // stands still on a steady tone.
    private func trigger(_ scope: FmSynthScope, _ span: Int) -> Int {
        let start = scope.head - 1 - span
        var above = scope.at(start)

        for back in 0..<span {
            let at = start - back
            let below = scope.at(at - 1)
            if below <= 0 && above > 0 { return at }
            above = below
        }

        return start
    }

    private func ribbon(_ from: SIMD2<Float>, _ to: SIMD2<Float>, _ thickness: Float,
                        _ color: SIMD4<Float>, _ vertices: UnsafeMutablePointer<VisualizerVertex>,
                        _ count: inout Int) {
        let half = thickness * 0.5
        vertices[count + 0] = VisualizerVertex(position: [from.x, from.y - half], color: color)
        vertices[count + 1] = VisualizerVertex(position: [from.x, from.y + half], color: color)
        vertices[count + 2] = VisualizerVertex(position: [to.x, to.y + half], color: color)
        vertices[count + 3] = VisualizerVertex(position: [to.x, to.y - half], color: color)
        count += 4
    }

    private func fade(_ color: SIMD4<Float>, _ column: Int, _ columns: Int) -> SIMD4<Float> {
        let position = Float(column) / Float(columns - 1)
        let edge = min(position, 1 - position) / VisualizerRenderer.fadeWidth
        return SIMD4(color.x, color.y, color.z, color.w * min(edge, 1))
    }

    // MARK: Constants

    static let maxColumns = 512
    static let traceHeight: Float = 0.42 // Of the half height, at full scale
    static let fadeWidth: Float = 0.12   // Of the width, at either end
    static let inFlight = 3

    // Style.NoteLine at two alphas, in linear light for the sRGB drawable — what
    // Visualizer.Shaded did for Unity's linear colour space.
    static let traceColor = shaded(Style.greyValue(0xe8), alpha: 0.10)
    static let channelColor = shaded(Style.greyValue(0xe8), alpha: 0.22)

    static func shaded(_ value: Float, alpha: Float) -> SIMD4<Float> {
        let l = linear(value)
        return SIMD4(l, l, l, alpha)
    }

    static func linear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private let engine: JacquardEngine
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertexBuffers: [MTLBuffer]
    private let indexBuffer: MTLBuffer
    private let inFlight = DispatchSemaphore(value: VisualizerRenderer.inFlight)
    private var frame = 0
}

// The MTKView under the interface. It clears to the ground the plane used to paint, so
// nothing above it paints one.
struct VisualizerView: UIViewRepresentable {
    let engine: JacquardEngine

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm_srgb
        let ground = Double(VisualizerRenderer.linear(Style.greyValue(0x16)))
        view.clearColor = MTLClearColor(red: ground, green: ground, blue: ground, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.isUserInteractionEnabled = false

        context.coordinator.renderer = VisualizerRenderer(view: view, engine: engine)
        view.delegate = context.coordinator.renderer
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    final class Coordinator {
        var renderer: VisualizerRenderer?
    }
}
