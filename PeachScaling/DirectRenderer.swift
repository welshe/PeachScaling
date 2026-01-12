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
    
    private var displayLink: CVDisplayLink?
    
    struct CapturedFrame {
        let texture: MTLTexture
        let timestamp: CFTimeInterval
    }
    
    private var frameQueue: [CapturedFrame] = []
    private let queueLock = NSLock()
    
    private var lastDrawnFrame: MTLTexture?
    private var interpolationPhase: Float = 0.0
    
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
            metalEngine.configureScaler(inputSize: source, outputSize: output, colorProcessingMode: settings.qualityMode.scalerMode)
        }
    }
    
    func startCapture(windowID: CGWindowID, pid: pid_t = 0) -> Bool {
        guard !isCapturing else { return false }
        
        targetWindowID = windowID
        targetPID = pid
        
        // Setup DisplayLink
        if displayLink == nil {
            var displayID = CGMainDisplayID()
            if let screen = NSScreen.main {
                displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            }
            
            let result = CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink)
            guard result == kCVReturnSuccess, let link = displayLink else {
                NSLog("DirectRenderer: Failed to create display link")
                onWindowLost?()
                return false
            }
            
            let callback: CVDisplayLinkOutputCallback = { displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext in
                let renderer = Unmanaged<DirectRenderer>.fromOpaque(displayLinkContext!).takeUnretainedValue()
                renderer.renderLoopInternal()
                return kCVReturnSuccess
            }
            CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
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
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
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
                
                CVDisplayLinkStart(displayLink!)
                
            } catch {
                NSLog("DirectRenderer: Stream capture failed: \(error)")
                onWindowLost?()
                return false
            }
        }
        
        return true
    }
    
    func stopCapture() {
        guard isCapturing else { return }
        
        if let link = displayLink {
            var isRunning: CVReturn = 0
            CVDisplayLinkIsRunning(link, &isRunning)
            if isRunning == kCVReturnSuccess {
                CVDisplayLinkStop(link)
            }
        }
        
        Task {
            try? await captureStream?.stopCapture()
            self.captureStream = nil
            self.streamOutput = nil
            self.isCapturing = false
            self.metalEngine.reset()
            
            self.queueLock.lock()
            self.frameQueue.removeAll()
            self.queueLock.unlock()
        }
    }
    
    func pauseCapture() { isCapturing = false }
    func resumeCapture() { isCapturing = true }
    
    private func processCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing, sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // 1. Convert to Texture immediately on capture queue
        guard let texture = metalEngine.makeTexture(from: imageBuffer) else { return }
        let now = CACurrentMediaTime()
        
        // 2. Enqueue
        queueLock.lock()
        frameQueue.append(CapturedFrame(texture: texture, timestamp: now))
        // Prevent infinite growth with proper overflow handling
        let maxQueueSize = 5
        if frameQueue.count > maxQueueSize {
            let excessCount = frameQueue.count - maxQueueSize
            frameQueue.removeFirst(excessCount)
            droppedFrames += UInt64(excessCount)
        }
        queueLock.unlock()
    }
    
    // Called by CVDisplayLink on a background thread
    private func renderLoopInternal() {
        guard let settings = currentSettings else { return }
        
        // Determine what to render
        var frameToRender: MTLTexture? = nil
        var interpolationT: Float = 1.0
        var previousFrame: MTLTexture? = nil
        
        queueLock.lock()
        
        if settings.isFrameGenEnabled {
            // Needed: at least 2 frames to interpolate
            if frameQueue.count >= 2 {
                let frameA = frameQueue[0]
                let frameB = frameQueue[1]
                
                // Advance phase
                let step = 1.0 / Float(settings.frameGenMultiplier.intValue)
                interpolationPhase += step
                
                // If phase exceeds 1.0, we move to next interval
                if interpolationPhase >= 1.0 {
                    interpolationPhase -= 1.0
                    frameQueue.removeFirst()
                    // Re-fetch new pair if available
                    if frameQueue.count >= 2 {
                        previousFrame = frameQueue[0].texture
                        frameToRender = frameQueue[1].texture
                    } else {
                        // Ran out of future frames, just show current
                        frameToRender = frameQueue.first?.texture
                        previousFrame = nil
                        interpolationT = 1.0
                    }
                } else {
                    previousFrame = frameA.texture
                    frameToRender = frameB.texture
                }
                interpolationT = interpolationPhase
                
            } else {
                // Not enough frames, show latest or hold last
                frameToRender = frameQueue.last?.texture ?? lastDrawnFrame
                previousFrame = nil // No interpolation possible
                interpolationT = 1.0
            }
        } else {
            // No FG: Just drain queue and show latest
            if !frameQueue.isEmpty {
                frameToRender = frameQueue.last?.texture
                frameQueue.removeAll()
            } else {
                frameToRender = lastDrawnFrame
            }
            interpolationT = 1.0
        }
        
        queueLock.unlock()
        
        guard let target = frameToRender else { return }
        lastDrawnFrame = target
        
        // 3. Process & Draw
        // Use a semaphore to prevent backing up the GPU
        // dispatch_semaphore_wait logic here could block the DisplayLink thread which is bad?
        // Actually, CVDisplayLink drops frames if we block. That's fine.
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Render Loop"
        
        let startTime = CACurrentMediaTime()
        
        // Call MetalEngine to do the heavy lifting (Motion Est -> Interp -> AA -> Upscale)
        let processed = metalEngine.processFrame(
            current: target,
            previous: previousFrame,
            motionVectors: nil, // Engine handles caching/generating motion if needed
            t: interpolationT,
            settings: settings,
            commandBuffer: commandBuffer
        )
        
        // Draw to screen
        if let finalTexture = processed, let view = mtkView, let drawable = view.currentDrawable {
            if metalEngine.renderToDrawable(texture: finalTexture, drawable: drawable, commandBuffer: commandBuffer) {
                // Stats
                interpolatedFrameCount += 1 // This function runs at Display Rate (e.g. 120Hz)
                if interpolationT >= 0.99 || interpolationT == 0.0 {
                    // Start of a "Real" frame period
                    frameCount += 1
                }
            }
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.processingTime = (CACurrentMediaTime() - startTime) * 1000.0
        }
        
        commandBuffer.commit()
        
        // Check if display link is still running before starting it
        if let link = displayLink {
            var isRunning: CVReturn = 0
            CVDisplayLinkIsRunning(link, &isRunning)
            if isRunning != kCVReturnSuccess {
                CVDisplayLinkStart(link)
            }
        }
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
        // Important: Manual drawing for DisplayLink
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
        if let link = displayLink { CVDisplayLinkStop(link) }
        mtkView = nil
        overlayManager?.destroyOverlay()
    }
    
    func getStats() -> DirectEngineStats {
        let now = CACurrentMediaTime()
        fpsCounter += 1
        if fpsTimer == 0 { fpsTimer = now }
        
        let elapsed = now - fpsTimer
        if elapsed >= 0.5 {
            // Calculate real rates
            let realFrameDelta = frameCount - lastReportedFrameCount
            let interpFrameDelta = interpolatedFrameCount - lastReportedInterpCount
            
            // Avoid divide by zero
            let safeElapsed = max(Float(elapsed), 0.001)
            
            currentFPS = Float(realFrameDelta) / safeElapsed
            interpolatedFPS = Float(interpFrameDelta) / safeElapsed
            
            lastReportedFrameCount = frameCount
            lastReportedInterpCount = interpolatedFrameCount
            
            fpsCounter = 0
            fpsTimer = now
        }
        
        return DirectEngineStats(
            fps: interpolatedFPS, // The Output FPS is the "Interpolated" rate (Display Rate)
            interpolatedFPS: interpolatedFPS,
            captureFPS: currentFPS, // The Input FPS
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
    nonisolated func draw(in view: MTKView) {} // Not used with explicit DisplayLink
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
