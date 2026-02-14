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

// MARK: - Metal Engine Errors
enum MetalEngineError: Error, LocalizedError {
    case deviceNotFound
    case commandQueueCreationFailed
    case textureCacheCreationFailed
    case libraryNotFound
    case functionNotFound(name: String)
    case pipelineCreationFailed(name: String, error: Error)
    case scalerCreationFailed
    case invalidSize
    case textureCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "Metal device not found"
        case .commandQueueCreationFailed:
            return "Failed to create Metal command queue"
        case .textureCacheCreationFailed:
            return "Failed to create texture cache"
        case .libraryNotFound:
            return "Metal library not found"
        case .functionNotFound(let name):
            return "Metal function '\(name)' not found"
        case .pipelineCreationFailed(let name, let error):
            return "Pipeline '\(name)' creation failed: \(error.localizedDescription)"
        case .scalerCreationFailed:
            return "Failed to create MetalFX scaler"
        case .invalidSize:
            return "Invalid texture size specified"
        case .textureCreationFailed:
            return "Failed to create texture"
        }
    }
}

// Global Constants for MetalEngine - Using AppConstants
// Removed local MetalConstants enum


@available(macOS 15.0, *)
final class MetalEngine {
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    
    var onWarning: ((String) -> Void)?
    
    // MARK: - Metal Error Log Handler
    private func logMetalError(_ message: String) {
        NSLog("MetalEngine Error: \(message)")
    }
    
    // Pipelines - Now optional to handle creation failures gracefully
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
    
    // MARK: - Initialization
    init?(device: MTLDevice? = nil) {
        // Safe device creation
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            NSLog("MetalEngine: Device creation failed")
            return nil
        }
        
        // Safe command queue creation
        guard let queue = dev.makeCommandQueue() else {
            NSLog("MetalEngine: Queue creation failed")
            return nil
        }
        
        self.device = dev
        self.commandQueue = queue
        
        // Safe texture cache creation
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let textureCache = cache else {
            NSLog("MetalEngine: Texture cache creation failed with status: \(cacheStatus)")
            return nil
        }
        self.textureCache = textureCache
        
        // Setup pipelines with error handling
        if !setupPipelines() {
            NSLog("MetalEngine: Pipeline setup had failures, some features may be unavailable")
        }
        
        setupSampler()
    }
    
    // MARK: - Pipeline Setup
    private func setupPipelines() -> Bool {
        guard let library = device.makeDefaultLibrary() else {
            NSLog("MetalEngine: Default library not found")
            return false
        }
        
        var allPipelinesSuccessful = true
        
        // Define compute kernels to compile with safe error handling
        let functions: [(String, UnsafeMutablePointer<MTLComputePipelineState?>)] = [
            ("interpolateFrames", &interpolatePSO),
            ("interpolateSimple", &interpolateSimplePSO),
            ("contrastAdaptiveSharpening", &sharpenPSO),
            ("applyFXAA", &fxaaPSO),
            ("applyFastEdgeSmoothing", &smaaPSO),
            ("applyTAA", &taaPSO),
            ("bilinearUpscale", &bilinearUpscalePSO),
            ("copyTexture", &copyPSO),
            ("estimateMotion", &motionEstimationPSO)
        ]
        
        for (name, pipelinePtr) in functions {
            if let function = library.makeFunction(name: name) {
                do {
                    let pipeline = try device.makeComputePipelineState(function: function)
                    pipelinePtr.pointee = pipeline
                } catch {
                    NSLog("MetalEngine: Failed to create PSO for \(name): \(error)")
                    allPipelinesSuccessful = false
                }
            } else {
                NSLog("MetalEngine: Function \(name) not found in library")
                allPipelinesSuccessful = false
            }
        }
        
        // Setup Render Pipeline for Drawing to Screen
        guard let vertexFunc = library.makeFunction(name: "texture_vertex"),
              let fragmentFunc = library.makeFunction(name: "texture_fragment") else {
            NSLog("MetalEngine: Vertex or fragment function not found")
            return false
        }
        
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.colorAttachments[0].isBlendingEnabled = false
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            NSLog("MetalEngine: Failed to create render pipeline state: \(error)")
            allPipelinesSuccessful = false
        }
        
        return allPipelinesSuccessful
    }
    
    // MARK: - Sampler Setup
    private func setupSampler() {
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerDesc.mipFilter = .notMipmapped
        samplerState = device.makeSamplerState(descriptor: samplerDesc)
    }
    
    // MARK: - Scaler Configuration
    func configureScaler(inputSize: CGSize, outputSize: CGSize, colorProcessingMode: MTLFXSpatialScalerColorProcessingMode = .perceptual) -> Bool {
        // Validate sizes
        guard inputSize.width > 0, inputSize.height > 0, outputSize.width > 0, outputSize.height > 0 else {
            logMetalError("Invalid size parameters for scaler")
            return false
        }
        
        let maxTextureSize = device.supportsFamily(.apple3) ? AppConstants.maxTextureSizeApple : AppConstants.maxTextureSizeDefault
        
        guard Int(outputSize.width) <= maxTextureSize, Int(outputSize.height) <= maxTextureSize else {
            logMetalError("Output size exceeds maximum texture size: \(maxTextureSize)")
            return false
        }
        
        // Check if existing scaler is still valid and parameters match
        if spatialScaler != nil,
           scalerInputSize == inputSize && scalerOutputSize == outputSize && scalerColorMode == colorProcessingMode {
            return true
        }
        
        // Explicitly release old resources
        outputTexture = nil
        spatialScaler = nil
        
        // Safe scaler creation
        guard let descriptor = MTLFXSpatialScalerDescriptor() else {
            logMetalError("Failed to create scaler descriptor")
            return false
        }
        
        descriptor.inputWidth = Int(inputSize.width)
        descriptor.inputHeight = Int(inputSize.height)
        descriptor.outputWidth = Int(outputSize.width)
        descriptor.outputHeight = Int(outputSize.height)
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = colorProcessingMode
        
        guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
            logMetalError("Failed to create spatial scaler")
            return false
        }
        
        spatialScaler = newScaler
        scalerInputSize = inputSize
        scalerOutputSize = outputSize
        scalerColorMode = colorProcessingMode
        
        // Safe texture creation
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            mipmapped: false
        )
        outputDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        outputDesc.storageMode = .private
        
        guard let outputTex = device.makeTexture(descriptor: outputDesc) else {
            logMetalError("Failed to create output texture")
            return false
        }
        
        outputTexture = outputTex
        
        return true
    }
    
    // MARK: - Texture Creation
    func makeTexture(from imageBuffer: CVImageBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            imageBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTex = cvTexture else {
            NSLog("MetalEngine: Failed to create texture from image buffer: \(status)")
            return nil
        }
        
        guard let texture = CVMetalTextureGetTexture(cvTex) else {
            NSLog("MetalEngine: Failed to get Metal texture from CV texture")
            return nil
        }
        
        return texture
    }
    
    /// Process a frame with full pipeline: Motion -> Interpolate (Optional) -> AA -> Upscale -> Sharpen
    /// Now stateless regarding "previousTexture" to allow renderer to manage frame history
    func processFrame(
        current: MTLTexture,
        previous: MTLTexture?,
        motionVectors: MTLTexture?,
        t: Float,
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        
        var processedTexture = current
        var currentMotion = motionVectors
        
        // 1. Motion Estimation (if needed & not provided)
        let needsMotion = settings.isFrameGenEnabled || settings.aaMode == .taa
        if needsMotion && currentMotion == nil, let prev = previous {
            currentMotion = generateMotionVectors(previous: prev, current: current, commandBuffer: commandBuffer)
        }
        
        // 2. Frame Interpolation
        if settings.isFrameGenEnabled, let prev = previous {
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
    
    // Legacy/Convenience wrapper for single-shot processing
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
    
    // MARK: - Motion Vector Generation
    func generateMotionVectors(previous: MTLTexture, current: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let pso = motionEstimationPSO else {
            NSLog("MetalEngine: Motion estimation PSO not available")
            return nil
        }
        
        let width = max(1, current.width / 8)
        let height = max(1, current.height / 8)
        
        let maxTextureSize = device.supportsFamily(.apple3) ? AppConstants.maxTextureSizeApple : AppConstants.maxTextureSizeDefault
        
        guard width > 0 && height > 0 && width <= maxTextureSize && height <= maxTextureSize else {
            NSLog("MetalEngine: Invalid motion texture dimensions")
            return nil
        }
        
        let finalWidth = width
        let finalHeight = height
        
        // Recreate motion texture if needed
        if motionTexture == nil || motionTexture?.width != finalWidth || motionTexture?.height != finalHeight {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg16Float,
                width: finalWidth,
                height: finalHeight,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            motionTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let output = motionTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            NSLog("MetalEngine: Failed to create motion estimation encoder")
            return nil
        }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(output, index: 2)
        
        let threads = MTLSize(
            width: (finalWidth + AppConstants.motionThreadgroupSize - 1) / AppConstants.motionThreadgroupSize,
            height: (finalHeight + AppConstants.motionThreadgroupSize - 1) / AppConstants.motionThreadgroupSize,
            depth: 1
        )
        encoder.dispatchThreadgroups(
            threads,
            threadsPerThreadgroup: MTLSize(
                width: AppConstants.motionThreadgroupSize,
                height: AppConstants.motionThreadgroupSize,
                depth: 1
            )
        )
        
        encoder.endEncoding()
        
        return output
    }
    
    // MARK: - Frame Interpolation
    private func interpolateFrames(
        previous: MTLTexture,
        current: MTLTexture,
        motionVectors: MTLTexture?,
        t: Float,
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        // Recreate texture if needed
        if interpolatedTexture == nil ||
           interpolatedTexture?.width != current.width ||
           interpolatedTexture?.height != current.height {
            
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: current.width,
                height: current.height,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            interpolatedTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let output = interpolatedTexture else {
            NSLog("MetalEngine: Failed to create interpolated texture")
            return nil
        }
        
        interpolation if available
        if let motion = motionVectors, let pso = // Use motion-based interpolatePSO, let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pso)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(previous, index: 1)
            encoder.setTexture(motion, index: 2)
            encoder.setTexture(output, index: 3)
            
            var constants = InterpolationConstants(
                interpolationFactor: t,
                motionScale: settings.motionScale,
                textureSize: SIMD2<Float>(Float(current.width), Float(current.height))
            )
            encoder.setBytes(&constants, length: MemoryLayout<InterpolationConstants>.size, index: 0)
            
            let threads = MTLSize(
                width: (current.width + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
                height: (current.height + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
                depth: 1
            )
            encoder.dispatchThreadgroups(
                threads,
                threadsPerThreadgroup: MTLSize(
                    width: AppConstants.threadgroupSize,
                    height: AppConstants.threadgroupSize,
                    depth: 1
                )
            )
            
            encoder.endEncoding()
            
            return output
        }
        
        // Fallback to simple interpolation
        guard let pso = interpolateSimplePSO,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            NSLog("MetalEngine: Failed to create interpolation encoder")
            return nil
        }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(output, index: 2)
        
        var tValue = t
        encoder.setBytes(&tValue, length: MemoryLayout<Float>.size, index: 0)
        
        let threads = MTLSize(
            width: (current.width + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            height: (current.height + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            depth: 1
        )
        encoder.dispatchThreadgroups(
            threads,
            threadsPerThreadgroup: MTLSize(
                width: AppConstants.threadgroupSize,
                height: AppConstants.threadgroupSize,
                depth: 1
            )
        )
        encoder.endEncoding()
        
        return output
    }
    
    // MARK: - Anti-Aliasing
    private func applyAntiAliasing(
        _ texture: MTLTexture,
        mode: CaptureSettings.AAMode,
        motionVectors: MTLTexture?,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        // TAA
        if mode == .taa, let pso = taaPSO {
            // Create history texture if needed
            if historyTexture == nil ||
               historyTexture?.width != texture.width ||
               historyTexture?.height != texture.height {
                
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: texture.pixelFormat,
                    width: texture.width,
                    height: texture.height,
                    mipmapped: false
                )
                desc.usage = [.shaderWrite, .shaderRead]
                desc.storageMode = .private
                historyTexture = device.makeTexture(descriptor: desc)
                
                // Initialize history with current frame
                if let hist = historyTexture {
                    if let blit = commandBuffer.makeBlitCommandEncoder() {
                        blit.copy(from: texture, to: hist)
                        blit.endEncoding()
                    } else {
                        NSLog("MetalEngine: Failed to create blit encoder for TAA history init")
                    }
                }
            }
            
            guard let history = historyTexture,
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                NSLog("MetalEngine: Failed to create TAA encoder")
                return texture
            }
            
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat,
                width: texture.width,
                height: texture.height,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            
            guard let output = device.makeTexture(descriptor: desc) else {
                NSLog("MetalEngine: Failed to create TAA output texture")
                return texture
            }
            
            encoder.setComputePipelineState(pso)
            encoder.setTexture(texture, index: 0)
            encoder.setTexture(history, index: 1)
            encoder.setTexture(motionVectors, index: 2)
            encoder.setTexture(output, index: 3)
            
            var constants = TAAConstants(
                modulation: AppConstants.taaModulation,
                textureSize: SIMD2<Float>(Float(texture.width), Float(texture.height))
            )
            encoder.setBytes(&constants, length: MemoryLayout<TAAConstants>.size, index: 0)
            
            let threads = MTLSize(
                width: (texture.width + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
                height: (texture.height + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
                depth: 1
            )
            encoder.dispatchThreadgroups(
                threads,
                threadsPerThreadgroup: MTLSize(
                    width: AppConstants.threadgroupSize,
                    height: AppConstants.threadgroupSize,
                    depth: 1
                )
            )
            encoder.endEncoding()
            
            // Update History
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
        if mode == .fxaa {
            pso = fxaaPSO
        } else if mode == .smaa {
            pso = smaaPSO
        } else {
            return texture
        }
        
        guard let pipeline = pso,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            NSLog("MetalEngine: Failed to create AA encoder")
            return texture
        }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        
        guard let output = device.makeTexture(descriptor: desc) else {
            NSLog("MetalEngine: Failed to create AA output texture")
            return texture
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(output, index: 1)
        
        var constants = AAConstants(
            threshold: AppConstants.aaThreshold,
            subpixelBlend: AppConstants.aaSubpixelBlend
        )
        encoder.setBytes(&constants, length: MemoryLayout<AAConstants>.size, index: 0)
        
        let threads = MTLSize(
            width: (texture.width + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            height: (texture.height + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            depth: 1
        )
        encoder.dispatchThreadgroups(
            threads,
            threadsPerThreadgroup: MTLSize(
                width: AppConstants.threadgroupSize,
                height: AppConstants.threadgroupSize,
                depth: 1
            )
        )
        encoder.endEncoding()
        
        return output
    }
    
    // MARK: - Upscaling
    private func upscale(
        _ texture: MTLTexture,
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let inputSize = CGSize(width: texture.width, height: texture.height)
        let outputSize = CGSize(
            width: inputSize.width * CGFloat(settings.scaleFactor.floatValue),
            height: inputSize.height * CGFloat(settings.scaleFactor.floatValue)
        )
        
        if settings.scalingType.usesMetalFX {
            let configured = configureScaler(
                inputSize: inputSize,
                outputSize: outputSize,
                colorProcessingMode: settings.qualityMode.scalerMode
            )
            
            guard configured, let scaler = spatialScaler, let output = outputTexture else {
                let msg = "MetalFX scaler not available, falling back to bilinear"
                NSLog("MetalEngine: \(msg)")
                onWarning?(msg)
                return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
            }
            
            scaler.colorTexture = texture
            scaler.outputTexture = output
            scaler.encode(commandBuffer: commandBuffer)
            return output
        }
        
        return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
    }
    
    // MARK: - Fallback Upscale
    private func fallbackUpscale(
        _ texture: MTLTexture,
        outputSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pso = bilinearUpscalePSO else {
            NSLog("MetalEngine: Bilinear upscale PSO not available")
            return texture
        }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        
        guard let output = device.makeTexture(descriptor: desc),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            NSLog("MetalEngine: Failed to create fallback upscale resources")
            return texture
        }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(output, index: 1)
        
        let threads = MTLSize(
            width: (Int(outputSize.width) + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            height: (Int(outputSize.height) + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            depth: 1
        )
        encoder.dispatchThreadgroups(
            threads,
            threadsPerThreadgroup: MTLSize(
                width: AppConstants.threadgroupSize,
                height: AppConstants.threadgroupSize,
                depth: 1
            )
        )
        encoder.endEncoding()
        
        return output
    }
    
    // MARK: - Sharpening
    private func applySharpen(
        _ texture: MTLTexture,
        intensity: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pso = sharpenPSO else {
            NSLog("MetalEngine: Sharpen PSO not available")
            return texture
        }
        
        // Recreate texture if needed
        if sharpenedTexture == nil ||
           sharpenedTexture?.width != texture.width ||
           sharpenedTexture?.height != texture.height {
            
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat,
                width: texture.width,
                height: texture.height,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            sharpenedTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let output = sharpenedTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            NSLog("MetalEngine: Failed to create sharpen resources")
            return texture
        }
        
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(output, index: 1)
        
        var constants = SharpenConstants(sharpness: intensity, radius: 1.0)
        encoder.setBytes(&constants, length: MemoryLayout<SharpenConstants>.size, index: 0)
        
        let threads = MTLSize(
            width: (texture.width + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            height: (texture.height + AppConstants.threadgroupSize - 1) / AppConstants.threadgroupSize,
            depth: 1
        )
        encoder.dispatchThreadgroups(
            threads,
            threadsPerThreadgroup: MTLSize(
                width: AppConstants.threadgroupSize,
                height: AppConstants.threadgroupSize,
                depth: 1
            )
        )
        encoder.endEncoding()
        
        return output
    }
    
    // MARK: - Render to Drawable
    func renderToDrawable(
        texture: MTLTexture,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let pipelineState = renderPipelineState,
              let sampler = samplerState else {
            NSLog("MetalEngine: Render pipeline or sampler not available")
            return false
        }
        
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            NSLog("MetalEngine: Failed to create render encoder")
            return false
        }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        return true
    }
    
    // MARK: - Reset
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
