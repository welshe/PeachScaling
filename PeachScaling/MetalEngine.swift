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

@available(macOS 15.0, *)
class MetalEngine {
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    
    private var interpolatePSO: MTLComputePipelineState?
    private var interpolateSimplePSO: MTLComputePipelineState?
    private var sharpenPSO: MTLComputePipelineState?
    private var fxaaPSO: MTLComputePipelineState?
    private var bilinearUpscalePSO: MTLComputePipelineState?
    private var copyPSO: MTLComputePipelineState?
    private var motionEstimationPSO: MTLComputePipelineState?
    
    private var renderPipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    
    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerInputSize: CGSize = .zero
    private var scalerOutputSize: CGSize = .zero
    private var scalerColorMode: MTLFXSpatialScalerColorProcessingMode = .perceptual
    
    private var previousTexture: MTLTexture?
    private var interpolatedTexture: MTLTexture?
    private var sharpenedTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var motionTexture: MTLTexture?
    
    private(set) var processingTime: Double = 0.0
    
    private var frameCount: Int = 0
    private var fpsUpdateTime: CFTimeInterval = 0
    
    init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            NSLog("MetalEngine: Failed to create Metal device")
            return nil
        }
        
        guard let queue = dev.makeCommandQueue() else {
            NSLog("MetalEngine: Failed to create command queue")
            return nil
        }
        
        self.device = dev
        self.commandQueue = queue
        
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard status == kCVReturnSuccess, let cache = cache else {
            NSLog("MetalEngine: Failed to create texture cache")
            return nil
        }
        self.textureCache = cache
        
        setupPipelines()
        setupSampler()
        
        NSLog("MetalEngine: Initialized successfully with device: \(dev.name)")
    }
    
    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            NSLog("MetalEngine: Failed to load default library")
            return
        }
        
        do {
            if let function = library.makeFunction(name: "interpolateFrames") {
                interpolatePSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "interpolateSimple") {
                interpolateSimplePSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "contrastAdaptiveSharpening") {
                sharpenPSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "applyFXAA") {
                fxaaPSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "bilinearUpscale") {
                bilinearUpscalePSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "copyTexture") {
                copyPSO = try device.makeComputePipelineState(function: function)
            }
            
            if let function = library.makeFunction(name: "estimateMotion") {
                motionEstimationPSO = try device.makeComputePipelineState(function: function)
            }
            
            NSLog("MetalEngine: Compute pipelines created successfully")
        } catch {
            NSLog("MetalEngine: Failed to create compute pipelines: \(error)")
        }
        
        do {
            guard let vertexFunc = library.makeFunction(name: "texture_vertex"),
                  let fragmentFunc = library.makeFunction(name: "texture_fragment") else {
                NSLog("MetalEngine: Failed to find vertex/fragment functions")
                return
            }
            
            let pipelineDesc = MTLRenderPipelineDescriptor()
            pipelineDesc.vertexFunction = vertexFunc
            pipelineDesc.fragmentFunction = fragmentFunc
            pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDesc.colorAttachments[0].isBlendingEnabled = false
            
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            NSLog("MetalEngine: Render pipeline created successfully")
        } catch {
            NSLog("MetalEngine: Failed to create render pipeline: \(error)")
        }
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
    
    func configureScaler(
        inputSize: CGSize,
        outputSize: CGSize,
        colorProcessingMode: MTLFXSpatialScalerColorProcessingMode = .perceptual
    ) {
        guard inputSize.width > 0, inputSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            NSLog("MetalEngine: Invalid scaler dimensions")
            return
        }
        
        let maxTextureSize = device.supportsFamily(.apple3) ? 16384 : 8192
        guard Int(outputSize.width) <= maxTextureSize,
              Int(outputSize.height) <= maxTextureSize else {
            NSLog("MetalEngine: Output size \(Int(outputSize.width))x\(Int(outputSize.height)) exceeds GPU max texture size \(maxTextureSize)")
            return
        }
        
        if scalerInputSize == inputSize && 
           scalerOutputSize == outputSize && 
           scalerColorMode == colorProcessingMode &&
           spatialScaler != nil {
            return
        }
        
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = Int(inputSize.width)
        descriptor.inputHeight = Int(inputSize.height)
        descriptor.outputWidth = Int(outputSize.width)
        descriptor.outputHeight = Int(outputSize.height)
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = colorProcessingMode
        
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            NSLog("MetalEngine: Failed to create MetalFX scaler")
            return
        }
        
        spatialScaler = scaler
        scalerInputSize = inputSize
        scalerOutputSize = outputSize
        scalerColorMode = colorProcessingMode
        
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            mipmapped: false
        )
        outputDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        outputDesc.storageMode = .private
        outputTexture = device.makeTexture(descriptor: outputDesc)
        
        NSLog("MetalEngine: Configured scaler - Input: \(Int(inputSize.width))x\(Int(inputSize.height)), Output: \(Int(outputSize.width))x\(Int(outputSize.height))")
    }
    
    func processFrame(
        _ imageBuffer: CVImageBuffer,
        settings: CaptureSettings,
        completion: @escaping (MTLTexture?) -> Void
    ) {
        guard let texture = makeTexture(from: imageBuffer) else {
            NSLog("MetalEngine: Failed to create texture from image buffer")
            completion(nil)
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            NSLog("MetalEngine: Failed to create command buffer")
            completion(nil)
            return
        }
        commandBuffer.label = "MetalEngine Processing"
        
        let startTime = CACurrentMediaTime()
        
        var processedTexture = texture
        
        if settings.isFrameGenEnabled, let previous = previousTexture {
            if let motion = generateMotionVectors(
                previous: previous,
                current: texture,
                commandBuffer: commandBuffer
            ) {
                motionTexture = motion
            }
            
            if let interpolated = interpolateFrames(
                previous: previous,
                current: texture,
                motionVectors: motionTexture,
                t: 0.5,
                settings: settings,
                commandBuffer: commandBuffer
            ) {
                processedTexture = interpolated
            }
        }
        
        if settings.aaMode != .off {
            if let aaResult = applyAntiAliasing(
                processedTexture,
                mode: settings.aaMode,
                commandBuffer: commandBuffer
            ) {
                processedTexture = aaResult
            }
        }
        
        if settings.isUpscalingEnabled {
            if let upscaled = upscale(
                processedTexture,
                settings: settings,
                commandBuffer: commandBuffer
            ) {
                processedTexture = upscaled
            }
        }
        
        let needsSharpening = settings.sharpening > 0.01 && 
                             (!settings.scalingType.usesMetalFX || 
                              settings.qualityMode == .performance)
        
        if needsSharpening {
            if let sharpened = applySharpen(
                processedTexture,
                intensity: settings.sharpening,
                commandBuffer: commandBuffer
            ) {
                processedTexture = sharpened
            }
        }
        
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self = self else { return }
            let endTime = CACurrentMediaTime()
            self.processingTime = (endTime - startTime) * 1000.0
            completion(processedTexture)
        }
        
        commandBuffer.commit()
        
        previousTexture = texture
    }
    
    private func generateMotionVectors(
        previous: MTLTexture,
        current: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pso = motionEstimationPSO else { return nil }
        
        let motionWidth = current.width / 8
        let motionHeight = current.height / 8
        
        if motionTexture == nil ||
           motionTexture!.width != motionWidth ||
           motionTexture!.height != motionHeight {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg16Float,
                width: motionWidth,
                height: motionHeight,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            motionTexture = device.makeTexture(descriptor: desc)
        }
        
        guard let outputTex = motionTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        encoder.label = "Motion Estimation"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(outputTex, index: 2)
        
        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(
            width: (motionWidth + 7) / 8,
            height: (motionHeight + 7) / 8,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    private func interpolateFrames(
        previous: MTLTexture,
        current: MTLTexture,
        motionVectors: MTLTexture?,
        t: Float,
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        
        if interpolatedTexture == nil ||
           interpolatedTexture!.width != current.width ||
           interpolatedTexture!.height != current.height {
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
        
        guard let outputTex = interpolatedTexture else { return nil }
        
        if let motion = motionVectors, let pso = interpolatePSO,
           let encoder = commandBuffer.makeComputeCommandEncoder() {
            
            encoder.label = "Frame Interpolation (Motion-Based)"
            encoder.setComputePipelineState(pso)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(previous, index: 1)
            encoder.setTexture(motion, index: 2)
            encoder.setTexture(outputTex, index: 3)
            
            var constants = InterpolationConstants(
                interpolationFactor: t,
                motionScale: settings.motionScale,
                textureSize: SIMD2<Float>(Float(current.width), Float(current.height))
            )
            encoder.setBytes(&constants, length: MemoryLayout<InterpolationConstants>.size, index: 0)
            
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (current.width + 15) / 16,
                height: (current.height + 15) / 16,
                depth: 1
            )
            
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
            
            return outputTex
        }
        
        guard let pso = interpolateSimplePSO,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        encoder.label = "Frame Interpolation (Simple)"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(current, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(outputTex, index: 2)
        
        var tValue = t
        encoder.setBytes(&tValue, length: MemoryLayout<Float>.size, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (current.width + 15) / 16,
            height: (current.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    private func applyAntiAliasing(
        _ texture: MTLTexture,
        mode: CaptureSettings.AAMode,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard mode == .fxaa, let pso = fxaaPSO else {
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
        
        guard let outputTex = device.makeTexture(descriptor: desc),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return texture
        }
        
        encoder.label = "FXAA"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTex, index: 1)
        
        var constants = AAConstants(threshold: 0.166, subpixelBlend: 0.75)
        encoder.setBytes(&constants, length: MemoryLayout<AAConstants>.size, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (texture.width + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    private func upscale(
        _ texture: MTLTexture,
        settings: CaptureSettings,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        
        let inputSize = CGSize(width: texture.width, height: texture.height)
        let scaleFactor = CGFloat(settings.scaleFactor.floatValue)
        let outputSize = CGSize(
            width: inputSize.width * scaleFactor,
            height: inputSize.height * scaleFactor
        )
        
        if settings.scalingType.usesMetalFX {
            configureScaler(
                inputSize: inputSize,
                outputSize: outputSize,
                colorProcessingMode: settings.qualityMode.scalerMode
            )
            
            guard let scaler = spatialScaler,
                  let output = outputTexture else {
                return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
            }
            
            scaler.colorTexture = texture
            scaler.outputTexture = output
            scaler.encode(commandBuffer: commandBuffer)
            
            return output
        } else {
            return fallbackUpscale(texture, outputSize: outputSize, commandBuffer: commandBuffer)
        }
    }
    
    private func fallbackUpscale(
        _ texture: MTLTexture,
        outputSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pso = bilinearUpscalePSO else { return texture }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        
        guard let outputTex = device.makeTexture(descriptor: desc),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return texture
        }
        
        encoder.label = "Bilinear Upscale"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTex, index: 1)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (Int(outputSize.width) + 15) / 16,
            height: (Int(outputSize.height) + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    private func applySharpen(
        _ texture: MTLTexture,
        intensity: Float,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pso = sharpenPSO else { return texture }
        
        if sharpenedTexture == nil ||
           sharpenedTexture!.width != texture.width ||
           sharpenedTexture!.height != texture.height {
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
        
        guard let outputTex = sharpenedTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return texture
        }
        
        encoder.label = "CAS Sharpening"
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTex, index: 1)
        
        var constants = SharpenConstants(sharpness: intensity, radius: 1.0)
        encoder.setBytes(&constants, length: MemoryLayout<SharpenConstants>.size, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (texture.width + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        return outputTex
    }
    
    private func makeTexture(from imageBuffer: CVImageBuffer) -> MTLTexture? {
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
            return nil
        }
        
        return CVMetalTextureGetTexture(cvTex)
    }
    
    func renderToDrawable(
        texture: MTLTexture,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let pipelineState = renderPipelineState,
              let sampler = samplerState else {
            NSLog("MetalEngine: Missing render pipeline or sampler")
            return false
        }
        
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            NSLog("MetalEngine: Failed to create render encoder")
            return false
        }
        
        renderEncoder.label = "Final Render"
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        return true
    }
    
    func reset() {
        previousTexture = nil
        interpolatedTexture = nil
        sharpenedTexture = nil
        motionTexture = nil
        frameCount = 0
        fpsUpdateTime = 0
    }
}
