import AppKit
import Metal
import QuartzCore

/// An actual opaque EDR sample keeps this experiment honest: a fully transparent
/// layer may be discarded by the compositor. This is a 4x4 point corner patch,
/// rendered once, with no screen capture, video, display link or render loop.
final class EDRPatch {
    let window: NSPanel
    let metalLayer: CAMetalLayer
    private let queue: MTLCommandQueue
    private(set) var frameCount = 0
    private(set) var gpuSeconds: Double = 0
    private var renderGeneration = UUID()
    private var pendingRender: ((Result<Void, Error>) -> Void)?
    private var renderTimeout: DispatchWorkItem?
    private var closed = false

    init(screen: NSScreen) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "HeadroomLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable."])
        }
        self.queue = queue
        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        metalLayer.drawableSize = CGSize(width: 8, height: 8)
        metalLayer.contentsScale = screen.backingScaleFactor
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.presentsWithTransaction = false
        let frame = NSRect(x: screen.frame.minX + 2, y: screen.frame.minY + 2, width: 4, height: 4)
        window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.hasShadow = false
        window.backgroundColor = .clear
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = metalLayer
        window.contentView = view
        window.orderFrontRegardless()
    }

    func render(value: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        let generation = UUID()
        renderGeneration = generation
        pendingRender = completion
        let timeout = DispatchWorkItem { [weak self] in
            self?.completeRender(generation: generation, result: .failure(NSError(domain: "HeadroomLab", code: 6, userInfo: [NSLocalizedDescriptionKey: "The EDR frame timed out. No transfer tables were changed."])))
        }
        renderTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        let layer = metalLayer, commandQueue = queue
        // Drawable acquisition and GPU completion must never block the UI's
        // stop, quit, or bounded-startup handling.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let drawable = layer.nextDrawable(), let buffer = commandQueue.makeCommandBuffer() else {
                DispatchQueue.main.async { self?.completeRender(generation: generation, result: .failure(NSError(domain: "HeadroomLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create an EDR frame."]))) }
                return
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                DispatchQueue.main.async { self?.completeRender(generation: generation, result: .failure(NSError(domain: "HeadroomLab", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode the EDR frame."]))) }
                return
            }
            encoder.endEncoding()
            buffer.addCompletedHandler { [weak self] completed in
                DispatchQueue.main.async {
                    let result: Result<Void, Error> = completed.status == .completed ? .success(()) : .failure(completed.error ?? NSError(domain: "HeadroomLab", code: 4))
                    self?.completeRender(generation: generation, result: result, gpuSeconds: max(0, completed.gpuEndTime - completed.gpuStartTime))
                }
            }
            buffer.present(drawable)
            buffer.commit()
        }
    }

    private func completeRender(generation: UUID, result: Result<Void, Error>, gpuSeconds: Double = 0) {
        guard !closed, generation == renderGeneration, let completion = pendingRender else { return }
        pendingRender = nil; renderTimeout?.cancel(); renderTimeout = nil
        if case .success = result { frameCount += 1; self.gpuSeconds += gpuSeconds }
        completion(result)
    }

    func close() {
        guard !closed else { return }; closed = true
        pendingRender = nil; renderTimeout?.cancel(); renderTimeout = nil
        window.orderOut(nil); metalLayer.wantsExtendedDynamicRangeContent = false; window.close()
    }
    deinit { close() }
}
