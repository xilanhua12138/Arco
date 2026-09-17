import SwiftUI
import MetalKit

/// Native Metal port of the official LiveKit Agents UI Aura shader and state parameters.
/// The original shader's license and attribution are included in Resources/Aura.
struct LiveKitAuraView: NSViewRepresentable {
    var status: GPTLiveSessionStatus
    var reduceMotion: Bool

    func makeCoordinator() -> Renderer { Renderer() }
    func makeNSView(context: Context) -> MTKView {
        let view = AuraMetalView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = true
        view.delegate = context.coordinator
        context.coordinator.update(status: status, reduceMotion: reduceMotion)
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(status: status, reduceMotion: reduceMotion)
        view.isPaused = reduceMotion
        if reduceMotion { view.draw() }
    }
    static func dismantleNSView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true
        view.delegate = nil
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var lastFrame = CACurrentMediaTime()
        private var time: Float = 0
        private var speed: Float = 10
        private var values = SIMD4<Float>(1.2, 0.4, 0.2, 1)
        private var target = SIMD4<Float>(1.2, 0.4, 0.2, 1)
        private var motionDisabled = false
        private var pulsing = false
        private var thinking = false
        private let inFlight = DispatchSemaphore(value: 2)

        override init() {
            super.init()
            guard let device, let url = Bundle.module.url(forResource: "LiveKitAura.metal", withExtension: "txt", subdirectory: "Aura") else { return }
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                let library = try device.makeLibrary(source: source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "auraVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "auraFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                queue = device.makeCommandQueue()
            } catch {
                NSLog("Arco Aura shader failed: %@", String(describing: error))
            }
        }
        func update(status: GPTLiveSessionStatus, reduceMotion: Bool) {
            motionDisabled = reduceMotion
            thinking = status.phase == .connecting || status.activity == .thinking
            pulsing = status.phase == .connected || status.phase == .connecting
            if status.phase == .idle || status.phase == .failed || status.phase == .disconnecting {
                speed = 10; target = SIMD4(1.2, 0.4, 0.2, 1)
            } else if thinking {
                speed = 30; target = SIMD4(0.5, 1, 0.3, 1.5)
            } else if status.activity == .speaking {
                speed = 70; target = SIMD4(0.75, 1.25, 0.2 + 0.2 * Float(status.audioLevel), 1.5)
                pulsing = false
            } else {
                speed = 20; target = SIMD4(1, 0.7, 0.3, 1.75)
            }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard view.window?.isVisible == true, inFlight.wait(timeout: .now()) == .success else { return }
            guard let pipeline, let command = queue?.makeCommandBuffer(),
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                inFlight.signal(); return
            }
            let now = CACurrentMediaTime()
            let dt = Float(min(now - lastFrame, 0.1)); lastFrame = now
            if !motionDisabled { time += dt }
            values += (target - values) * min(1, dt * 8)
            var brightness = values.w
            if pulsing && !motionDisabled {
                brightness += sin(time * .pi / 0.35) * (thinking ? 1 : 0.25)
            }
            // Match LiveKit's uniform layout and per-state parameter transitions.
            var uniforms = [Float(view.drawableSize.width), Float(view.drawableSize.height),
                            time, speed, values.x, values.y, values.z, brightness]
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Float>.stride * uniforms.count, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            let semaphore = inFlight
            command.addCompletedHandler { _ in semaphore.signal() }
            command.commit()
        }
    }
}

private final class AuraMetalView: MTKView {
    override var mouseDownCanMoveWindow: Bool { false }
}
