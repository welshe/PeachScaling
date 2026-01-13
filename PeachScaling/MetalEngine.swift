import Metal
import MetalKit
import MetalFX
import CoreVideo
import Accelerate

struct InterpolationConstants {
    var interpolationFactor: Float
    var motionScale: Float
    var textureSize: SIMD2<Float>
}

struct SharpenConstants {
    var sharpness: Float
    var radius: Float
}

struct AAConstants {
    var threshold: Float
    var subpixelBlend: Float
}

struct TAAConstants {
    var modulation: Float
    var textureSize: SIMD2<Float>
}

// Global Constants for MetalEngine
enum MetalConstants {
    static let threadgroupSize = 16
    static let motionThreadgroupSize = 8
    static let taaModulation: Float = 0.1
    static let aaThreshold: Float = 0.1
    static let aaSubpixelBlend: Float = 0.75
}

@available(macOS 15.0, *)
final class MetalEngine {
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    
    // Pipelines
    private var interpolatePSO: MTLComputePipelineState?
    private var interpolateSimplePSO: MTLComputePipelineState?
    private var sharpenPSO: MTLComputePipelineState?
    private var fxaaPSO: MTLComputePipelineState?
    private var smaaPSO: MTLComputePipelineState?
    private var taaPSO: MTLComputePipelineState?
    private var bilinearUpscalePSO: MTLComputePipelineState?
    private var copyPSO: MTLComputePipelineState?
    private var motionEstimationPSO: MTLComputePipelineState?
    
    private var renderPipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    
    // MetalFX Scaler
    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerInputSize: CGSize = .zero
    private var scalerOutputSize: CGSize = .zero
    private var scalerColorMode: MTLFXSpatialScalerColorProcessingMode = .perceptual
    
    // Textures
    private var previousTexture: MTLTexture?
    private var historyTexture: MTLTexture?
    private var interpolatedTexture: MTLTexture?
    private var sharpenedTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var motionTexture: MTLTexture?
    
    private(set) var processingTime: Double = 0.0
    private var frameCount: Int = 0
    private var fpsUpdateTime: CFTimeInterval = 0
    
    init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { 
            NSLog("MetalEngine: Device creation failed")
            return nil 
        }
        guard let queue = dev.makeCommandQueue() else { 
            NSLog("MetalEngine: Queue creation failed")
            return nil 
        }
        
        self.device = dev
        self.commandQueue = queue
        
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else { 
            NSLog("MetalEngine: Texture cache creation failed")
            return nil 
        }
        self.textureCache = textureCache
        
        setupPipelines()
        setupSampler()
    }
    
    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else { 
            NSLog("MetalEngine: Default library not found")
            return 
        }
        
        // Define compute kernels to compile
        let functions = [
            ("interpolateFrames", \MetalEngine.interpolatePSO),
            ("interpolateSimple", \MetalEngine.interpolateSimplePSO),
            ("contrastAdaptiveSharpening", \MetalEngine.sharpenPSO),
            ("applyFXAA", \MetalEngine.fxaaPSO),
            ("applyFastEdgeSmoothing", \MetalEngine.smaaPSO),
            ("applyTAA", \MetalEngine.taaPSO),
            ("bilinearUpscale", \MetalEngine.bilinearUpscalePSO),
            ("copyTexture", \MetalEngine.copyPSO),
            ("estimateMotion", \MetalEngine.motionEstimationPSO)
        ]
        
        for (name, keyPath) in functions {
            if let function = library.makeFunction(name: name) {
                do {
                    self[keyPath: keyPath] = try device.makeComputePipelineState(function: function)
                } catch {
                    NSLog("MetalEngine: Failed to create PSO for \(name): \(error)")
                }
            } else {
                 NSLog("MetalEngine: Function \(name) not found in library")
            }
        }
        
        // Setup Render Pipeline for Drawing to Screen
        guard let vertexFunc = library.makeFunction(name: "texture_vertex"),
              let fragmentFunc = library.makeFunction(name: "texture_fragment") else { return }
        
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.colorAttachments[0].isBlendingEnabled = false
        
        renderPipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDesc)
    }
    
    private func setupSampler() {
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerDesc.mipFilter = .notMipmapped
        samplerState = device.makeSamplerState(descriptor: samplerDesc)
    }
    
    func configureScaler(inputSize: CGSize, outputSize: CGSize, colorProcessingMode: MTLFXSpatialScalerColorProcessingMode = .perceptual) -> Bool {
        guard inputSize.width > 0, inputSize.height > 0, outputSize.width > 0, outputSize.height > 0 else { return false }
        
        let kMaxTextureSizeApple = 16384
        let kMaxTextureSizeDefault = 8192
        let maxTextureSize = device.supportsFamily(.apple3) ? kMaxTextureSizeApple : kMaxTextureSizeDefault
        guard Int(outputSize.width) <= maxTextureSize, Int(outputSize.height) <= maxTextureSize else { return false }
        
        // Check if existing scaler is still valid and parameters match
        if spatialScaler != nil,
           scalerInputSize == inputSize && scalerOutputSize == outputSize && scalerColorMode == colorProcessingMode {
            return true
        }
        
        // Explicitly release old resources
        outputTexture = nil
        spatialScaler = nil
        
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = Int(inputSize.width)
        descriptor.inputHeight = Int(inputSize.height)
        descriptor.outputWidth = Int(outputSize.width)
        descriptor.outputHeight = Int(outputSize.height)
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = colorProcessingMode
        
        guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
            NSLog("MetalEngine: Failed to create spatial scaler")
            return false
        }
        
        spatialScaler = newScaler
        scalerInputSize = inputSize
        scalerOutputSize = outputSize
        scalerColorMode = colorProcessingMode
        
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(outputSize.width), height: Int(outputSize.height), mipmapped: false)
        outputDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        outputDesc.storageMode = .private
        outputTexture = device.makeTexture(descriptor: outputDesc)
        
        return outputTexture != nil
    }
    
    func makeTexture(from imageBuffer: CVImageBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, imageBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTex = cvTexture else { return nil }
        
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Process a frame with full pipeline: Motion -> Interpolate (Optional) -> AA -> Upscale -> Sharpen
    /// Now stateless regarding "previousTexture" to allow renderer to manage frame history
    func processFrame(
        current: MTLTexture,
        previous: MTLTexture?,
        motionVectors: MTLTexture?, // Pre-calculated or nil
        t: Float, // Interpolation factor (0.0 = previous, 1.0 = current)
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        
        var processedTexture = current
        var currentMotion = motionVectors
        
        // 1. Motion Estimation (if needed & not provided)
        // We need motion vectors if TAA is on OR Frame Gen is on
        let needsMotion = settings.isFrameGenEnabled || settings.aaMode == .taa
        if needsMotion && currentMotion == nil, let prev = previous {
            currentMotion = generateMotionVectors(previous: prev, current: current, commandBuffer: commandBuffer)
        }
        
        // 2. Frame Interpolation
        if settings.isFrameGenEnabled, let prev = previous {
            // If FG is on, we interpolate between Previous and Current using 't'
            // NOTE: If t=1.0, we just show Current. If t=0.5, we show mix.
            if let interpolated = interpolateFrames(
                previous: prev, 
                current: current, 
                motionVectors: currentMotion, 
                t: t, 
                settings: settings, 
                commandBuffer: commandBuffer
            ) {
                processedTexture = interpolated
            }
        }
        
        // 3. Anti-Aliasing
        if settings.aaMode != .off {
           if let result = applyAntiAliasing(processedTexture, mode: settings.aaMode, motionVectors: currentMotion, commandBuffer: commandBuffer) {
                processedTexture = result
            }
        }
        
        // 4. Upscaling
        if settings.isUpscalingEnabled {
            if let upscaled = upscale(processedTexture, settings: settings, commandBuffer: commandBuffer) {
                processedTexture = upscaled
            }
        }
        
        // 5. Sharpening
        let needsSharpening = settings.sharpening > 0.01 && (!settings.scalingType.usesMetalFX || settings.qualityMode == .performance)
        if needsSharpening {
            if let sharpened = applySharpen(processedTexture, intensity: settings.sharpening, commandBuffer: commandBuffer) {
                processedTexture = sharpened
            }
        }
        
        return processedTexture
    }

    // Legacy/Convenience wrapper for single-shot processing (if needed by other parts)
    func processFrameSingle(
        _ imageBuffer: CVImageBuffer,
        settings: CaptureSettings,
        completion: @escaping (MTLTexture?) -> Void
    ) {
         guard let texture = makeTexture(from: imageBuffer),
               let commandBuffer = commandQueue.makeCommandBuffer() else {
             completion(nil)
             return
         }
         
         // In single shot mode, we manage state internally again? 
         // Or strictly deprecated. Let's keep a functional path for tests.
         let result = processFrame(
            current: texture,
            previous: previousTexture,
            motionVectors: nil,
            t: 1.0,
            settings: settings,
            commandBuffer: commandBuffer
         )
         
         commandBuffer.addCompletedHandler { [weak self] _ in 
             self?.previousTexture = texture
             completion(result) 
         }
         commandBuffer.commit()
    }
    
    // Changed visibility to internal for DirectRenderer access
    func generateMotionVectors(previous: MTLTexture, current: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let pso = motionEstimationPSO else { return nil }
        
        let width = max(1, current.width / 8)
        let height = max(1, current.height / 8)
        
        let kMaxTextureSizeApple = 16384
        let kMaxTextureSizeDefault = 8192
        let maxTextureSize = device.supportsFamily(.apple3) ? kMaxTextureSizeApple : kMaxTextureSizeDefault
        
        guard width > 0 && height > 0 && width <= maxTextureSize && height <= maxTextureSize else {
            return nil
        }
        
        let finalWidth = width
        let finalHeight = height
        
        if motionTexture == nil || motionTexture?.width != finalWidth || motionTexture?.height != finalHeight {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: finalWidth, height: finalHeight, mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            motionTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let output = motionTexture, let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(output, index: 2)
        
        let threads = MTLSize(width: (finalWidth + MetalConstants.motionThreadgroupSize - 1) / MetalConstants.motionThreadgroupSize, height: (finalHeight + MetalConstants.motionThreadgroupSize - 1) / MetalConstants.motionThreadgroupSize, depth: 1)
        encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: MTLSize(width: MetalConstants.motionThreadgroupSize, height: MetalConstants.motionThreadgroupSize, depth: 1))
        encoder.endEncoding()
        
        return output
    }
    
    private func interpolateFrames(previous: MTLTexture, current: MTLTexture, motionVectors: MTLTexture?, t: Float, settings: CaptureSettings, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if interpolatedTexture == nil || interpolatedTexture?.width != current.width || interpolatedTexture?.height != current.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: current.width, height: current.height, mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            interpolatedTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let output = interpolatedTexture else { return nil }
        
        if let motion = motionVectors, let pso = interpolatePSO, let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pso)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(previous, index: 1)
            encoder.setTexture(motion, index: 2)
            encoder.setTexture(output, index: 3)
            
            var constants = InterpolationConstants(interpolationFactor: t, motionScale: settings.motionScale, textureSize: SIMD2<Float>(Float(current.width), Float(current.height)))
            encoder.setBytes(&constants, length: MemoryLayout<InterpolationConstants>.size, index: 0)
            
            let threads = MTLSize(width: (current.width + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, height: (current.height + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, depth: 1)
            encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: MTLSize(width: MetalConstants.threadgroupSize, height: MetalConstants.threadgroupSize, depth: 1))
            encoder.endEncoding()
            
            return output
        }
        
        // Fallback to simple interpolation if no motion vectors
        guard let pso = interpolateSimplePSO, let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(output, index: 2)
        
        var tValue = t
        encoder.setBytes(&tValue, length: MemoryLayout<Float>.size, index: 0)
        
        let threads = MTLSize(width: (current.width + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, height: (current.height + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, depth: 1)
        encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: MTLSize(width: MetalConstants.threadgroupSize, height: MetalConstants.threadgroupSize, depth: 1))
        encoder.endEncoding()
        
        return output
    }
    
    private func applyAntiAliasing(_ texture: MTLTexture, mode: CaptureSettings.AAMode, motionVectors: MTLTexture?, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if mode == .taa, let pso = taaPSO {
            // TAA Logic
            if historyTexture == nil || historyTexture?.width != texture.width || historyTexture?.height != texture.height {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
                desc.usage = [.shaderWrite, .shaderRead]
                desc.storageMode = .private
                historyTexture = device.makeTexture(descriptor: desc)
                
                // Initialize history with current frame to avoid black/garbage startup
                if let hist = historyTexture {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.copy(from: texture, to: hist)
                        blit.endEncoding()
                    } else {
                        NSLog("MetalEngine: Failed to create blit encoder for TAA history init")
                    }
                }
            }
            
            guard let history = historyTexture, let encoder = commandBuffer.makeComputeCommandEncoder() else { return texture }
            
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            guard let output = device.makeTexture(descriptor: desc) else { return texture }
            
            encoder.setComputePipelineState(pso)
            encoder.setTexture(texture, index: 0)
            encoder.setTexture(history, index: 1)
            encoder.setTexture(motionVectors, index: 2)
            encoder.setTexture(output, index: 3)
            
            var constants = TAAConstants(modulation: MetalConstants.taaModulation, textureSize: SIMD2<Float>(Float(texture.width), Float(texture.height)))
            encoder.setBytes(&constants, length: MemoryLayout<TAAConstants>.size, index: 0)
            
            let threads = MTLSize(width: (texture.width + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, height: (texture.height + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, depth: 1)
            encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: MTLSize(width: MetalConstants.threadgroupSize, height: MetalConstants.threadgroupSize, depth: 1))
            encoder.endEncoding()
            
            // Update History: Copy output to history for next frame
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: output, to: history)
                blit.endEncoding()
            } else {
                 NSLog("MetalEngine: Failed to create blit encoder for TAA history update")
            }
            
            return output
        }
        
        // FXAA or SMAA
        let pso: MTLComputePipelineState?
        if mode == .fxaa { pso = fxaaPSO }
        else if mode == .smaa { pso = smaaPSO }
        else { return texture }
        
        guard let pso, let encoder = commandBuffer.makeComputeCommandEncoder() else { return texture }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        
        guard let output = device.makeTexture(descriptor: desc) else { return texture }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(output, index: 1)
        
        var constants = AAConstants(threshold: MetalConstants.aaThreshold, subpixelBlend: MetalConstants.aaSubpixelBlend)
        encoder.setBytes(&constants, length: MemoryLayout<AAConstants>.size, index: 0)
        
        let threads = MTLSize(width: (texture.width + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, height: (texture.height + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, depth: 1)
        encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: MTLSize(width: MetalConstants.threadgroupSize, height: MetalConstants.threadgroupSize, depth: 1))
        encoder.endEncoding()
        
        return output
    }
    
    private func upscale(_ texture: MTLTexture, settings: CaptureSettings, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let inputSize = CGSize(width: texture.width, height: texture.height)
        let outputSize = CGSize(width: inputSize.width * CGFloat(settings.scaleFactor.floatValue), height: inputSize.height * CGFloat(settings.scaleFactor.floatValue))
        
        if settings.scalingType.usesMetalFX {
            _ = configureScaler(inputSize: inputSize, outputSize: outputSize, colorProcessingMode: settings.qualityMode.scalerMode)
            
            guard let scaler = spatialScaler, let output = outputTexture else {
                NSLog("MetalEngine: MetalFX scaler not available, falling back to bilinear")
                return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
            }
            
            scaler.colorTexture = texture
            scaler.outputTexture = output
            scaler.encode(commandBuffer: commandBuffer)
            return output
        }
        
        return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
    }
    
    private func fallbackUpscale(_ texture: MTLTexture, outputSize: CGSize, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let pso = bilinearUpscalePSO else { return texture }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: Int(outputSize.width), height: Int(outputSize.height), mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        
        guard let output = device.makeTexture(descriptor: desc), let encoder = commandBuffer.makeComputeCommandEncoder() else { return texture }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(output, index: 1)
        
        let threads = MTLSize(width: (Int(outputSize.width) + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, height: (Int(outputSize.height) + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, depth: 1)
        encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: MTLSize(width: MetalConstants.threadgroupSize, height: MetalConstants.threadgroupSize, depth: 1))
        encoder.endEncoding()
        
        return output
    }
    
    private func applySharpen(_ texture: MTLTexture, intensity: Float, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let pso = sharpenPSO else { return texture }
        
        if sharpenedTexture == nil || sharpenedTexture?.width != texture.width || sharpenedTexture?.height != texture.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            sharpenedTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let output = sharpenedTexture, let encoder = commandBuffer.makeComputeCommandEncoder() else { return texture }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(output, index: 1)
        
        var constants = SharpenConstants(sharpness: intensity, radius: 1.0)
        encoder.setBytes(&constants, length: MemoryLayout<SharpenConstants>.size, index: 0)
        
        let threads = MTLSize(width: (texture.width + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, height: (texture.height + MetalConstants.threadgroupSize - 1) / MetalConstants.threadgroupSize, depth: 1)
        encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: MTLSize(width: MetalConstants.threadgroupSize, height: MetalConstants.threadgroupSize, depth: 1))
        encoder.endEncoding()
        
        return output
    }
    
    // Moved makeTexture to public scope earlier

    
    func renderToDrawable(texture: MTLTexture, drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let pipelineState = renderPipelineState, let sampler = samplerState else { return false }
        
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return false }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        return true
    }
    
    func reset() {
        previousTexture = nil
        historyTexture = nil
        interpolatedTexture = nil
        sharpenedTexture = nil
        motionTexture = nil
        spatialScaler = nil
        outputTexture = nil
        frameCount = 0
        fpsUpdateTime = 0
    }
}
