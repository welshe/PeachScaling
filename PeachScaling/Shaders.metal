#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct InterpolationConstants {
    float interpolationFactor;
    float motionScale;
    float2 textureSize;
};

struct SharpenConstants {
    float sharpness;
    float radius;
};

struct AAConstants {
    float threshold;
    float subpixelBlend;
};

struct TAAConstants {
    float modulation;
    float2 textureSize;
};

float luminance(float3 color) {
    return dot(color, float3(0.299, 0.587, 0.114));
}

// ============================================================================
// MARK: - Vertex & Fragment Shaders
// ============================================================================

vertex VertexOut texture_vertex(uint vid [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    const float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texCoords[vid];
    return out;
}

fragment float4 texture_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.texCoord);
}

// ============================================================================
// MARK: - Motion Estimation (Optimized O(N^2))
// ============================================================================

kernel void estimateMotion(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> previousFrame [[texture(1)]],
    texture2d<float, access::write> motionVectors [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= motionVectors.get_width() || gid.y >= motionVectors.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 texSize = float2(currentFrame.get_width(), currentFrame.get_height());
    float2 uv = (float2(gid) + 0.5) / float2(motionVectors.get_width(), motionVectors.get_height());
    
    const int searchRadius = 4;
    
    // Center pixel for comparison
    float3 centerCurr = currentFrame.sample(s, uv).rgb;
    
    float2 bestMotion = float2(0.0);
    float bestError = 1e10;
    
    for (int dy = -searchRadius; dy <= searchRadius; dy++) {
        for (int dx = -searchRadius; dx <= searchRadius; dx++) {
            float2 offset = float2(dx, dy) / texSize;
            float2 testUV = uv + offset;
            
            float3 prev = previousFrame.sample(s, testUV).rgb;
            float error = length(centerCurr - prev); // Simplified per-pixel error for speed
            
            if (error < bestError) {
                bestError = error;
                bestMotion = float2(dx, dy);
            }
        }
    }
    
    motionVectors.write(float4(bestMotion, 0.0, 1.0), gid);
}

// ============================================================================
// MARK: - Frame Interpolation
// ============================================================================

kernel void interpolateFrames(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> previousFrame [[texture(1)]],
    texture2d<float, access::sample> motionVectors [[texture(2)]],
    texture2d<float, access::write> outputFrame [[texture(3)]],
    constant InterpolationConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputFrame.get_width() || gid.y >= outputFrame.get_height()) {
        return;
    }

    float2 texSize = float2(outputFrame.get_width(), outputFrame.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 motion = float2(0.0);
    if (!is_null_texture(motionVectors)) {
        motion = motionVectors.sample(s, uv).xy * constants.motionScale;
    }
    
    float t = constants.interpolationFactor;
    
    float2 forwardUV = uv + (motion * t / texSize);
    float2 backwardUV = uv - (motion * (1.0 - t) / texSize);
    
    float4 colorPrev = previousFrame.sample(s, backwardUV);
    float4 colorCurr = currentFrame.sample(s, forwardUV);
    
    float4 result = mix(colorPrev, colorCurr, t);
    
    outputFrame.write(result, gid);
}

kernel void interpolateSimple(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> previousFrame [[texture(1)]],
    texture2d<float, access::write> outputFrame [[texture(2)]],
    constant float &t [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputFrame.get_width() || gid.y >= outputFrame.get_height()) {
        return;
    }

    float2 texSize = float2(outputFrame.get_width(), outputFrame.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float4 colorPrev = previousFrame.sample(s, uv);
    float4 colorCurr = currentFrame.sample(s, uv);
    
    float4 result = mix(colorPrev, colorCurr, t);
    
    outputFrame.write(result, gid);
}

// ============================================================================
// MARK: - Anti-Aliasing (TAA, SMAA, FXAA)
// ============================================================================

kernel void applyTAA(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> historyFrame [[texture(1)]],
    texture2d<float, access::sample> motionVectors [[texture(2)]],
    texture2d<float, access::write> outputFrame [[texture(3)]],
    constant TAAConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputFrame.get_width() || gid.y >= outputFrame.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 texSize = constants.textureSize;
    float2 uv = (float2(gid) + 0.5) / texSize;

    float3 colorCurr = currentFrame.sample(s, uv).rgb;
    
    // Reproject history using motion vectors
    float2 motion = float2(0.0);
    if (!is_null_texture(motionVectors)) {
        motion = motionVectors.sample(s, uv).xy;
    }
    
    float2 historyUV = uv - (motion / texSize); // Motion is in pixels for us
    
    // Check bounds
    if (historyUV.x < 0.0 || historyUV.x > 1.0 || historyUV.y < 0.0 || historyUV.y > 1.0) {
        outputFrame.write(float4(colorCurr, 1.0), gid);
        return;
    }
    
    float3 colorHist = historyFrame.sample(s, historyUV).rgb;
    
    // Neighborhood Clamping (AAC)
    float3 c00 = currentFrame.sample(s, uv + float2(-1, -1) / texSize).rgb;
    float3 c10 = currentFrame.sample(s, uv + float2( 1, -1) / texSize).rgb;
    float3 c01 = currentFrame.sample(s, uv + float2(-1,  1) / texSize).rgb;
    float3 c11 = currentFrame.sample(s, uv + float2( 1,  1) / texSize).rgb;
    
    float3 minColor = min(min(min(c00, c10), min(c01, c11)), colorCurr);
    float3 maxColor = max(max(max(c00, c10), max(c01, c11)), colorCurr);
    
    colorHist = clamp(colorHist, minColor, maxColor);
    
    // Temporal Blend
    float modulation = constants.modulation;
    float3 result = mix(colorHist, colorCurr, modulation);
    
    outputFrame.write(float4(result, 1.0), gid);
}

kernel void applySMAA(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant AAConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 texSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    
    float3 center = inputTexture.sample(s, uv).rgb;
    float lumC = luminance(center);
    
    // Luma Edge Detection
    float lumL = luminance(inputTexture.sample(s, uv + float2(-1.0, 0.0) / texSize).rgb);
    float lumT = luminance(inputTexture.sample(s, uv + float2(0.0, -1.0) / texSize).rgb);
    
    float deltaX = abs(lumC - lumL);
    float deltaY = abs(lumC - lumT);
    
    float maxDelta = max(deltaX, deltaY);
    if (maxDelta < constants.threshold) {
        outputTexture.write(float4(center, 1.0), gid);
        return;
    }
    
    // Simplified 1-pass blend (Edge-Directed Reconstruction)
    float weights = 0.5;
    float3 result = center;
    
    // If horizontal edge, blend vertical
    if (deltaY > deltaX) {
         result = mix(center, (inputTexture.sample(s, uv + float2(0.0, 1.0)/texSize).rgb + 
                               inputTexture.sample(s, uv - float2(0.0, 1.0)/texSize).rgb) * 0.5, weights);
    } else {
         result = mix(center, (inputTexture.sample(s, uv + float2(1.0, 0.0)/texSize).rgb + 
                               inputTexture.sample(s, uv - float2(1.0, 0.0)/texSize).rgb) * 0.5, weights);
    }
    
    outputTexture.write(float4(result, 1.0), gid);
}

kernel void applyFXAA(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant AAConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 texSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    float2 texelSize = 1.0 / texSize;
    
    float3 rgbM = inputTexture.sample(s, uv).rgb;
    
    float lumM = luminance(rgbM);
    
    // Simple Luma Neighborhood
    float lumNW = luminance(inputTexture.sample(s, uv + float2(-1, -1) * texelSize).rgb);
    float lumNE = luminance(inputTexture.sample(s, uv + float2( 1, -1) * texelSize).rgb);
    float lumSW = luminance(inputTexture.sample(s, uv + float2(-1,  1) * texelSize).rgb);
    float lumSE = luminance(inputTexture.sample(s, uv + float2( 1,  1) * texelSize).rgb);
    
    float lumMin = min(lumM, min(min(lumNW, lumNE), min(lumSW, lumSE)));
    float lumMax = max(lumM, max(max(lumNW, lumNE), max(lumSW, lumSE)));
    float lumRange = lumMax - lumMin;
    
    if (lumRange < max(constants.threshold, lumMax * 0.125)) {
        outputTexture.write(float4(rgbM, 1.0), gid);
        return;
    }
    
    float lumL = (lumNW + lumNE + lumSW + lumSE) * 0.25;
    float rangeL = abs(lumL - lumM);
    float blendL = max(0.0, (rangeL / lumRange) - 0.25) * (1.0 / 0.75);
    blendL = min(blendL, constants.subpixelBlend);
    
    float3 rgbL = inputTexture.sample(s, uv + float2(0, blendL) * texelSize).rgb;
    
    float3 result = mix(rgbM, rgbL, blendL);
    outputTexture.write(float4(result, 1.0), gid);
}

// ============================================================================
// MARK: - Upscaling, Sharpening & Copy
// ============================================================================

kernel void contrastAdaptiveSharpening(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant SharpenConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    
    float2 texSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    float2 texelSize = 1.0 / texSize;
    
    float3 e = inputTexture.sample(s, uv).rgb;
    float3 b = inputTexture.sample(s, uv + float2( 0, -1) * texelSize).rgb;
    float3 d = inputTexture.sample(s, uv + float2(-1,  0) * texelSize).rgb;
    float3 f = inputTexture.sample(s, uv + float2( 1,  0) * texelSize).rgb;
    float3 h = inputTexture.sample(s, uv + float2( 0,  1) * texelSize).rgb;
    
    float3 minRGB = min(min(d, e), min(f, b));
    float3 maxRGB = max(max(d, e), max(f, b));
    
    float3 contrast = maxRGB - minRGB;
    float3 amp = clamp(contrast * constants.sharpness, 0.0, 1.0);
    
    float3 w = amp * -0.125;
    float3 result = saturate(e + (b + d + f + h) * w);
    
    outputTexture.write(float4(result, 1.0), gid);
}

kernel void bilinearUpscale(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / outputSize;
    
    float4 color = inputTexture.sample(s, uv);
    outputTexture.write(color, gid);
}

kernel void copyTexture(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float4 color = inputTexture.read(gid);
    outputTexture.write(color, gid);
}
