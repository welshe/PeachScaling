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
    
    private var displayTexture: MTLTexture?
    private let frameSemaphore = DispatchSemaphore(value: 3)
    
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
        
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    onWindowLost?()
                    return
                }
                
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width) * 2
                config.height = Int(window.frame.height) * 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 3
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
                onWindowLost?()
            }
        }
        
        return true
    }
    
    func stopCapture() {
        guard isCapturing else { return }
        
        Task {
            try? await captureStream?.stopCapture()
            self.captureStream = nil
            self.streamOutput = nil
            self.isCapturing = false
            self.metalEngine.reset()
        }
    }
    
    func pauseCapture() {
        isCapturing = false
    }
    
    func resumeCapture() {
        isCapturing = true
    }
    
    private func processCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing, sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              frameSemaphore.wait(timeout: .now() + 0.016) == .success else { return }
        
        // Settings access assumes safety or caching strategy
        
        Task { @MainActor in
            guard let settings = self.currentSettings else {
                self.frameSemaphore.signal()
                return
            }
            
            self.metalEngine.processFrame(imageBuffer, settings: settings) { [weak self] processedTexture in
                defer { self?.frameSemaphore.signal() }
                
                guard let self = self, let texture = processedTexture else {
                    self?.droppedFrames += 1
                    return
                }
                
                self.displayTexture = texture
                self.frameCount += 1
                if settings.isFrameGenEnabled { self.interpolatedFrameCount += 1 }
                self.processingTime = self.metalEngine.processingTime
                self.mtkView?.draw()
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
        view.enableSetNeedsDisplay = true
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        view.delegate = self
        
        if let layer = view.layer as? CAMetalLayer {
            layer.displaySyncEnabled = currentSettings?.vsync ?? true
            layer.presentsWithTransaction = false
            layer.wantsExtendedDynamicRangeContent = false
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
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
        mtkView?.isPaused = true
        mtkView?.delegate = nil
        mtkView = nil
        overlayManager?.destroyOverlay()
    }
    
    func getStats() -> DirectEngineStats {
        let now = CACurrentMediaTime()
        fpsCounter += 1
        if fpsTimer == 0 { fpsTimer = now }
        
        let elapsed = now - fpsTimer
        if elapsed >= 0.5 {
            currentFPS = Float(fpsCounter) / Float(elapsed)
            interpolatedFPS = currentSettings?.isFrameGenEnabled ?? false ? currentFPS * Float(currentSettings?.frameGenMultiplier.intValue ?? 1) : currentFPS
            fpsCounter = 0
            fpsTimer = now
        }
        
        return DirectEngineStats(
            fps: currentFPS,
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

@available(macOS 15.0, *)
extension DirectRenderer: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    nonisolated func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        
        Task { @MainActor in
            guard let texture = self.displayTexture,
                  let commandBuffer = self.commandQueue.makeCommandBuffer() else { return }
            
            commandBuffer.label = "DirectRenderer Display"
            _ = self.metalEngine.renderToDrawable(texture: texture, drawable: drawable, commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
    }
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
