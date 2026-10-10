import AppKit
import AVFoundation
import QuartzCore

/// An independently implemented, paused HDR carrier. This does not capture the
/// screen, start playback, loop video, or modify display transfer tables.
/// Construct, prepare and close the carrier on the main thread.
public final class HDRCarrier {
    public let windowFrame: NSRect
    public let sampleFrame = NSRect(x: 0, y: 0, width: 1, height: 1)
    public var isReadyForDisplay: Bool { playerLayer.isReadyForDisplay }
    public var playbackRate: Float { player.rate }

    private let window: NSPanel
    private let item: AVPlayerItem
    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private var statusObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var timeout: Timer?
    private var settle: Timer?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var generation = UUID()
    private var preparing = false
    private var prepared = false
    private var closed = false

    public init(screen: NSScreen) throws {
        guard Thread.isMainThread else {
            throw Self.error(1, "The HDR carrier must be created on the main thread.")
        }
        guard let resource = Bundle.module.url(forResource: "black-hlg", withExtension: "mov") else {
            throw Self.error(2, "The independently generated HDR sample is missing.")
        }
        // Keep the 1-point sample visible at this display's upper-left edge.
        // This intentionally adapts the reference geometry for multiple displays.
        windowFrame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 5, height: 5)
        window = NSPanel(contentRect: windowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.hidesOnDeactivate = false
        window.alphaValue = 1
        window.level = NSWindow.Level(rawValue: 23)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        item = AVPlayerItem(url: resource)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.rate = 0
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = sampleFrame
        playerLayer.videoGravity = .resize
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 5, height: 5))
        view.wantsLayer = true
        view.alphaValue = 1
        view.layer?.masksToBounds = true
        view.layer?.addSublayer(playerLayer)
        window.contentView = view
    }

    public func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread, "HDRCarrier.prepare must run on the main thread")
        guard !closed else { completion(.failure(Self.error(3, "The HDR carrier is already closed."))); return }
        guard !preparing else { completion(.failure(Self.error(4, "The HDR carrier is already preparing."))); return }
        if prepared { completion(.success(())); return }
        preparing = true
        self.completion = completion
        let token = UUID()
        generation = token
        let timeout = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            self?.finish(token: token, result: .failure(Self.error(5, "The paused HDR sample did not become ready within eight seconds.")))
        }
        self.timeout = timeout
        // Native menu tracking uses a nested run loop; all preparation work
        // must remain eligible while the brightness menu is still open.
        RunLoop.main.add(timeout, forMode: .common)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            RunLoop.main.perform(inModes: [.common]) { self?.checkStatus(token: token) }
        }
        displayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            RunLoop.main.perform(inModes: [.common]) { self?.checkStatus(token: token) }
        }
        window.orderFrontRegardless()
    }

    private func checkStatus(token: UUID) {
        guard !closed, preparing, generation == token else { return }
        switch item.status {
        case .failed:
            finish(token: token, result: .failure(item.error ?? Self.error(6, "The paused HDR sample could not be loaded.")))
        case .readyToPlay:
            guard playerLayer.isReadyForDisplay, settle == nil else { return }
            let work = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self, !self.closed, self.preparing, self.generation == token else { return }
                guard self.item.status == .readyToPlay, self.playerLayer.isReadyForDisplay, self.player.error == nil else {
                    self.finish(token: token, result: .failure(self.item.error ?? self.player.error ?? Self.error(7, "The HDR sample stopped being ready.")))
                    return
                }
                // Loading readiness is an API-level condition. The app still
                // checks live EDR headroom and asks the user to assess gain.
                self.finish(token: token, result: .success(()))
            }
            settle = work
            RunLoop.main.add(work, forMode: .common)
        case .unknown: break
        @unknown default:
            finish(token: token, result: .failure(Self.error(8, "The HDR sample reported an unsupported preparation state.")))
        }
    }

    private func finish(token: UUID, result: Result<Void, Error>) {
        guard !closed, preparing, generation == token, let callback = completion else { return }
        completion = nil
        preparing = false
        timeout?.invalidate(); timeout = nil
        settle?.invalidate(); settle = nil
        statusObservation?.invalidate(); statusObservation = nil
        displayObservation?.invalidate(); displayObservation = nil
        if case .success = result { prepared = true }
        else { close() }
        callback(result)
    }

    public func close() {
        precondition(Thread.isMainThread, "HDRCarrier.close must run on the main thread")
        guard !closed else { return }
        closed = true; prepared = false; preparing = false
        generation = UUID()
        completion = nil
        timeout?.invalidate(); timeout = nil
        settle?.invalidate(); settle = nil
        statusObservation?.invalidate(); statusObservation = nil
        displayObservation?.invalidate(); displayObservation = nil
        window.orderOut(nil)
        player.rate = 0
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
        player.replaceCurrentItem(with: nil)
        window.close()
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Headroom.HDRCarrier", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    deinit {
        // Main-thread ownership is part of this AppKit object's contract.
        // Explicit close also makes cleanup deterministic on every stop path.
        close()
    }
}
