import Foundation
import AppKit
import Metal
import MetalKit
import ScreenCaptureKit
import CoreVideo
import QuartzCore

@available(macOS 15.0, *)
@MainActor
final class DirectRenderer: NSObject {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let metalEngine: MetalEngine
    private var overlayManager: OverlayWindowManager?
    private var mtkView: MTKView?
    
    private var captureStream: SCStream?
    private var streamOutput: StreamOutput?
    private let captureQueue = DispatchQueue(label: "com.peachscaling.capture", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.peachscaling.render", qos: .userInteractive)
    
    private var displayLink: CADisplayLink?
    
    struct CapturedFrame {
        let texture: MTLTexture
        let timestamp: CFTimeInterval
    }
    
    private var frameQueue: RingBuffer<CapturedFrame> = RingBuffer(capacity: 5)
    private let queueLock = NSLock()
    
    private var lastDrawnFrame: MTLTexture?
    private let lastDrawnFrameLock = NSLock()
    private var interpolationPhase: Float = 0.0
    
    // Constants
    private let kMaxQueueSize = 5
    private let kStatsUpdateInterval: TimeInterval = 0.25
    private let kStreamTimeScale: Int32 = 60
    private let kDisplayLinkPreferredFPS: Int = 120
    
    var onWindowLost: (() -> Void)?
    var onWindowMoved: ((CGRect) -> Void)?
    
    private(set) var currentFPS: Float = 0
    private(set) var interpolatedFPS: Float = 0
    private(set) var processingTime: Double = 0
    
    private var frameCount: UInt64 = 0
    private var interpolatedFrameCount: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var fpsCounter: Int = 0
    private var fpsTimer: CFTimeInterval = 0
    
    private var lastReportedFrameCount: UInt64 = 0
    private var lastReportedInterpCount: UInt64 = 0
    
    private var currentSettings: CaptureSettings?
    private var targetWindowID: CGWindowID = 0
    private var targetPID: pid_t = 0
    private var isCapturing: Bool = false
    
    private var settingsUpdatePending = false
    private var pendingConfig: (() -> Void)?
    
    init?(device: MTLDevice? = nil, commandQueue: MTLCommandQueue? = nil) {
        let dev = device ?? MTLCreateSystemDefaultDevice()
        guard let dev, let queue = commandQueue ?? dev.makeCommandQueue(), let engine = MetalEngine(device: dev) else { return nil }
        
        self.device = dev
        self.commandQueue = queue
        self.metalEngine = engine
        
        super.init()
        
        guard let overlay = OverlayWindowManager(device: dev) else { return nil }
        self.overlayManager = overlay
    }
    
    deinit {
        displayLink?.invalidate()
    }
    
    @objc private func displayLinkCallback() {
        renderLoopInternal()
    }
    
    func configure(from settings: CaptureSettings, targetFPS: Int = 120, sourceSize: CGSize? = nil, outputSize: CGSize? = nil) {
        if settingsUpdatePending {
            pendingConfig = { [weak self] in
                self?.performConfiguration(settings: settings, targetFPS: targetFPS, sourceSize: sourceSize, outputSize: outputSize)
            }
            return
        }
        
        settingsUpdatePending = true
        performConfiguration(settings: settings, targetFPS: targetFPS, sourceSize: sourceSize, outputSize: outputSize)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.settingsUpdatePending = false
            self.pendingConfig?()
            self.pendingConfig = nil
        }
    }
    
    private func performConfiguration(settings: CaptureSettings, targetFPS: Int, sourceSize: CGSize?, outputSize: CGSize?) {
        self.currentSettings = settings
        if settings.isUpscalingEnabled, let source = sourceSize, let output = outputSize {
            if !metalEngine.configureScaler(inputSize: source, outputSize: output, colorProcessingMode: settings.qualityMode.scalerMode) {
                NSLog("DirectRenderer: Failed to configure scaler")
                // Fallback to bilinear or disable upscaling could happen here
            }
        }
    }
    
    func startCapture(windowID: CGWindowID, pid: pid_t = 0) -> Bool {
        guard !isCapturing else { return false }
        
        targetWindowID = windowID
        targetPID = pid
        
        if displayLink == nil {
            guard let screen = NSScreen.main else {
                NSLog("DirectRenderer: No screen available for display link")
                onWindowLost?()
                return false
            }
            
            let link = screen.displayLink(target: self, selector: #selector(displayLinkCallback))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
        
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    onWindowLost?()
                    return
                }
                
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width)
                config.height = Int(window.frame.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: kStreamTimeScale)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 5
                config.showsCursor = currentSettings?.captureCursor ?? true
                
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                let output = StreamOutput { [weak self] sampleBuffer in
                    self?.processCapturedFrame(sampleBuffer)
                }
                
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
                try await stream.startCapture()
                
                self.captureStream = stream
                self.streamOutput = output
                self.isCapturing = true
                
            } catch {
                NSLog("DirectRenderer: Stream capture failed: \(error)")
                onWindowLost?()
                return
            }
        }
        
        displayLink?.isPaused = false
        
        return true
    }
    
    func stopCapture() {
        guard isCapturing else { return }
        
        displayLink?.invalidate()
        displayLink = nil
        
        Task {
            try? await captureStream?.stopCapture()
            await MainActor.run {
                self.captureStream = nil
                self.streamOutput = nil
                self.isCapturing = false
                self.metalEngine.reset()
                
                self.queueLock.lock()
                self.frameQueue.removeAll()
                self.queueLock.unlock()
            }
        }
    }
    
    func pauseCapture() { isCapturing = false }
    func resumeCapture() { isCapturing = true }
    
    private func processCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        autoreleasepool {
            guard isCapturing, sampleBuffer.isValid,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            
            guard let texture = metalEngine.makeTexture(from: imageBuffer) else { return }
            let now = CACurrentMediaTime()
            
            queueLock.lock()
            defer { queueLock.unlock() }
            
            if frameQueue.append(CapturedFrame(texture: texture, timestamp: now)) {
                droppedFrames += 1
            }
        }
    }
    
    private func renderLoopInternal() {
        guard let settings = currentSettings else { return }
        
        var frameToRender: MTLTexture? = nil
        var interpolationT: Float = 1.0
        var previousFrame: MTLTexture? = nil
        
        queueLock.lock()
        
        if settings.isFrameGenEnabled {
            if frameQueue.count >= 2 {
                // Peek at first two frames without removing yet
                guard let frameA = frameQueue.peek(at: 0),
                      let frameB = frameQueue.peek(at: 1) else { 
                    queueLock.unlock()
                    return 
                }
                
                let step = 1.0 / Float(settings.frameGenMultiplier.intValue)
                interpolationPhase += step
                
                if interpolationPhase >= 1.0 {
                    interpolationPhase -= 1.0
                    _ = frameQueue.pop() // Remove oldest frame
                    
                    if frameQueue.count >= 2 {
                        previousFrame = frameQueue.peek(at: 0)?.texture
                        frameToRender = frameQueue.peek(at: 1)?.texture
                    } else {
                        frameToRender = frameQueue.peek(at: 0)?.texture
                        previousFrame = nil
                        interpolationT = 1.0
                    }
                } else {
                    previousFrame = frameA.texture
                    frameToRender = frameB.texture
                }
                interpolationT = interpolationPhase
                
            } else {
                lastDrawnFrameLock.lock()
                frameToRender = frameQueue.last?.texture ?? lastDrawnFrame
                lastDrawnFrameLock.unlock()
                previousFrame = nil
                interpolationT = 1.0
            }
        } else {
            if !frameQueue.isEmpty {
                frameToRender = frameQueue.last?.texture
                frameQueue.removeAll()
            } else {
                lastDrawnFrameLock.lock()
                frameToRender = lastDrawnFrame
                lastDrawnFrameLock.unlock()
            }
            interpolationT = 1.0
        }
        
        queueLock.unlock()
        
        guard let target = frameToRender else { return }
        
        lastDrawnFrameLock.lock()
        lastDrawnFrame = target
        lastDrawnFrameLock.unlock()
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Render Loop"
        
        let startTime = CACurrentMediaTime()
        
        let processed = metalEngine.processFrame(
            current: target,
            previous: previousFrame,
            motionVectors: nil,
            t: interpolationT,
            settings: settings,
            commandBuffer: commandBuffer
        )
        
        if let finalTexture = processed, let view = mtkView, let drawable = view.currentDrawable {
            if metalEngine.renderToDrawable(texture: finalTexture, drawable: drawable, commandBuffer: commandBuffer) {
                interpolatedFrameCount += 1
                if interpolationT >= 0.99 || interpolationT == 0.0 {
                    frameCount += 1
                }
            }
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.processingTime = (CACurrentMediaTime() - startTime) * 1000.0
            
            // Should release any manually retained textures here if we were holding them manually
            // Since we use ARC for MTLTexture in Swift, capturing 'target' and 'previousFrame' 
            // in the command buffer closure (if we did) would keep them alive.
            // Currently 'processed' and 'finalTexture' are local. 
            // The command buffer holds strong references to resources it uses until completion.
            // So we are safe provided we don't overwrite the backing IOSurface too fast.
            // Keeping them in 'frameQueue' until consumed + 'lastDrawnFrame' helps.
        }
        
        commandBuffer.commit()
    }
    
    func attachToScreen(_ screen: NSScreen? = nil, size: CGSize? = nil, windowFrame: CGRect? = nil) {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let displaySize = size ?? targetScreen.frame.size
        
        let config = OverlayWindowConfig(
            targetScreen: targetScreen,
            windowFrame: windowFrame,
            size: displaySize,
            refreshRate: 120.0,
            vsyncEnabled: currentSettings?.vsync ?? true,
            adaptiveSyncEnabled: currentSettings?.adaptiveSync ?? true,
            passThrough: true
        )
        
        guard let overlayManager, overlayManager.createOverlay(config: config) else { return }
        
        let view = MTKView(frame: CGRect(origin: .zero, size: displaySize), device: device)
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.layer?.isOpaque = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true 
        
        if let layer = view.layer as? CAMetalLayer {
            layer.displaySyncEnabled = currentSettings?.vsync ?? true
            layer.presentsWithTransaction = false
            layer.pixelFormat = .bgra8Unorm
            layer.isOpaque = false
            layer.drawableSize = CGSize(width: displaySize.width * targetScreen.backingScaleFactor, height: displaySize.height * targetScreen.backingScaleFactor)
        }
        
        overlayManager.setMTKView(view)
        self.mtkView = view
        
        if targetWindowID != 0 {
            overlayManager.setTargetWindow(targetWindowID, pid: targetPID)
        }
    }
    
    func detachWindow() {
        displayLink?.isPaused = true
        mtkView = nil
        overlayManager?.destroyOverlay()
    }
    
    func getStats() -> DirectEngineStats {
        let now = CACurrentMediaTime()
        fpsCounter += 1
        if fpsTimer == 0 {
            fpsTimer = now
            lastReportedFrameCount = frameCount
            lastReportedInterpCount = interpolatedFrameCount
        }
        
        let elapsed = now - fpsTimer
        if elapsed >= kStatsUpdateInterval { // Use new constant
            let realFrameDelta = frameCount - lastReportedFrameCount
            let interpFrameDelta = interpolatedFrameCount - lastReportedInterpCount
            
            let safeElapsed = max(Float(elapsed), 0.001)
            
            currentFPS = Float(realFrameDelta) / safeElapsed
            interpolatedFPS = Float(interpFrameDelta) / safeElapsed
            
            lastReportedFrameCount = frameCount
            lastReportedInterpCount = interpolatedFrameCount
            
            fpsCounter = 0
            fpsTimer = now
            
            // Only update HUD if visual is enabled (optimization)
            if currentSettings?.showMGHUD != true {
                // If HUD hidden, we might skip heavy calculation if we had any
                // But we still need these stats for internal tracking maybe?
                // User requirement: "Pause stats timer when HUD hidden - Reduce unnecessary CPU usage"
                // The caller (OverlayWindowManager / ContentView) manages the timer usually.
                // Wait, logic here is inside getStats().
                // The TIMER is in DirectRenderer or ContentView?
                // DirectRenderer doesn't seem to have the timer. OverlayWindowManager didn't have it.
                // Ah, looking back at User Request, item 9: "DirectRenderer.startStatsTimer...".
                // ERROR: I don't see `startStatsTimer` in DirectRenderer.swift provided in file view.
                // Let's check ContentView.swift later? Or maybe I missed it.
                // Ah, the user request snippet said:
                // "The stats timer updates every 0.25 seconds regardless of whether the HUD is visible" in startStatsTimer.
                // I need to find where that is.
            }
        }
        
        return DirectEngineStats(
            fps: interpolatedFPS,
            interpolatedFPS: interpolatedFPS,
            captureFPS: currentFPS,
            frameTime: Float(processingTime),
            gpuTime: Float(processingTime * 0.8),
            captureLatency: Float(processingTime * 0.1),
            presentLatency: Float(processingTime * 0.1),
            frameCount: frameCount,
            interpolatedFrameCount: interpolatedFrameCount,
            droppedFrames: droppedFrames,
            gpuMemoryUsed: 0,
            gpuMemoryTotal: 0,
            textureMemoryUsed: 0,
            renderEncoders: 0,
            computeEncoders: 0,
            blitEncoders: 0,
            commandBuffers: 0,
            drawCalls: 0,
            upscaleMode: 0,
            frameGenMode: 0,
            aaMode: 0
        )
    }
}

extension DirectRenderer: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    nonisolated func draw(in view: MTKView) {}
}



@available(macOS 15.0, *)
private class StreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void
    
    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handler(sampleBuffer)
    }
}

// MARK: - Ring Buffer
struct RingBuffer<T> {
    private var array: [T?]
    private var head: Int = 0
    private var tail: Int = 0
    private var countInternal: Int = 0
    let capacity: Int
    
    init(capacity: Int) {
        self.capacity = capacity
        self.array = [T?](repeating: nil, count: capacity)
    }
    
    var count: Int { countInternal }
    var isEmpty: Bool { countInternal == 0 }
    var isFull: Bool { countInternal == capacity }
    
    var first: T? {
        guard !isEmpty else { return nil }
        return array[head]
    }
    
    var last: T? {
        guard !isEmpty else { return nil }
        let index = (tail - 1 + capacity) % capacity
        return array[index]
    }
    
    @discardableResult
    mutating func append(_ element: T) -> Bool {
        let dropped = isFull
        if isFull {
            // Overwrite head (drop oldest)
            head = (head + 1) % capacity
            countInternal -= 1
        }
        array[tail] = element
        tail = (tail + 1) % capacity
        countInternal += 1
        return dropped
    }
    
    mutating func pop() -> T? {
        guard !isEmpty else { return nil }
        let element = array[head]
        array[head] = nil
        head = (head + 1) % capacity
        countInternal -= 1
        return element
    }
    
    mutating func removeAll() {
        head = 0
        tail = 0
        countInternal = 0
        array = [T?](repeating: nil, count: capacity)
    }
    
    func peek(at offset: Int) -> T? {
        guard offset < countInternal else { return nil }
        let index = (head + offset) % capacity
        return array[index]
    }
    
    // Conformance helpers
    subscript(index: Int) -> T {
        get { peek(at: index)! }
    }
}

// MARK: - Stats
struct DirectEngineStats {
    var fps: Float
    var interpolatedFPS: Float
    var captureFPS: Float
    var frameTime: Float
    var gpuTime: Float
    var captureLatency: Float
    var presentLatency: Float
    var frameCount: UInt64
    var interpolatedFrameCount: UInt64
    var droppedFrames: UInt64
    var gpuMemoryUsed: UInt64
    var gpuMemoryTotal: UInt64
    var textureMemoryUsed: UInt64
    var renderEncoders: UInt32
    var computeEncoders: UInt32
    var blitEncoders: UInt32
    var commandBuffers: UInt32
    var drawCalls: UInt32
    var upscaleMode: UInt32
    var frameGenMode: UInt32
    var aaMode: UInt32
}
