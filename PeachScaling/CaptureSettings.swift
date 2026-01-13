import SwiftUI
import MetalFX

@available(macOS 15.0, *)
final class CaptureSettings: ObservableObject {

    
    @Published var selectedProfile: String = "Default"
    @Published var profiles: [String] = ["Default", "Performance", "Quality", "Ultra"]
    
    enum RenderScale: String, CaseIterable, Identifiable {
        case native = "Native"
        case p75 = "75%"
        case p67 = "67%"
        case p50 = "50%"
        case p33 = "33%"
        
        var id: String { rawValue }
        
        var multiplier: Float {
            switch self {
            case .native: return 1.0
            case .p75: return 0.75
            case .p67: return 0.67
            case .p50: return 0.50
            case .p33: return 0.33
            }
        }
    }
    
    enum ScalingType: String, CaseIterable, Identifiable {
        case off = "Off"
        case mgup1 = "MGUP-1"
        case mgup1Fast = "MGUP-1 Fast"
        case mgup1Quality = "MGUP-1 Quality"
        
        var id: String { rawValue }
        
        var usesMetalFX: Bool {
            switch self {
            case .off, .mgup1Fast: return false
            case .mgup1, .mgup1Quality: return true
            }
        }
    }
    
    enum QualityMode: String, CaseIterable, Identifiable {
        case performance = "Performance"
        case balanced = "Balanced"
        case ultra = "Ultra"
        
        var id: String { rawValue }
        
        var scalerMode: MTLFXSpatialScalerColorProcessingMode {
            switch self {
            case .performance: return .linear
            case .balanced: return .perceptual
            case .ultra: return .hdr
            }
        }
    }
    
    enum ScaleFactorOption: String, CaseIterable, Identifiable {
        case x1 = "1.0x"
        case x1_5 = "1.5x"
        case x2 = "2.0x"
        case x2_5 = "2.5x"
        case x3 = "3.0x"
        case x4 = "4.0x"
        case x5 = "5.0x"
        case x6 = "6.0x"
        case x8 = "8.0x"
        case x10 = "10.0x"
        
        var id: String { rawValue }
        
        var floatValue: Float {
            switch self {
            case .x1: return 1.0
            case .x1_5: return 1.5
            case .x2: return 2.0
            case .x2_5: return 2.5
            case .x3: return 3.0
            case .x4: return 4.0
            case .x5: return 5.0
            case .x6: return 6.0
            case .x8: return 8.0
            case .x10: return 10.0
            }
        }
    }
    
    enum FrameGenMode: String, CaseIterable, Identifiable {
        case off = "Off"
        case mgfg1 = "MGFG-1"
        
        var id: String { rawValue }
        
        var description: String {
             switch self {
             case .off: return "Lowest latency, no extra frames"
             case .mgfg1: return "Optical-flow generation"
             }
        }
    }
    
    enum FrameGenType: String, CaseIterable, Identifiable {
        case adaptive = "Adaptive"
        case fixed = "Fixed"
        
        var id: String { rawValue }
    }
    
    enum TargetFPS: String, CaseIterable, Identifiable {
        case fps60 = "60 FPS"
        case fps90 = "90 FPS"
        case fps120 = "120 FPS"
        case fps144 = "144 FPS"
        case fps165 = "165 FPS"
        case fps180 = "180 FPS"
        case fps240 = "240 FPS"
        case fps360 = "360 FPS"
        
        var id: String { rawValue }
        
        var intValue: Int {
            switch self {
            case .fps60: return 60
            case .fps90: return 90
            case .fps120: return 120
            case .fps144: return 144
            case .fps165: return 165
            case .fps180: return 180
            case .fps240: return 240
            case .fps360: return 360
            }
        }
    }
    
    enum FrameGenMultiplier: String, CaseIterable, Identifiable {
        case x2 = "2x"
        case x3 = "3x"
        case x4 = "4x"
        
        var id: String { rawValue }
        
        var intValue: Int {
            switch self {
            case .x2: return 2
            case .x3: return 3
            case .x4: return 4
            }
        }
    }
    
    enum AAMode: String, CaseIterable, Identifiable {
        case off = "Off"
        case fxaa = "FXAA"
        case smaa = "SMAA"
        case taa = "TAA"
        
        var id: String { rawValue }
        
        var description: String {
             switch self {
             case .off: return "No anti-aliasing"
             case .fxaa: return "Fast Approximate AA"
             case .smaa: return "Fast Edge Smoothing"
             case .taa: return "Temporal AA (Anti-Ghosting)"
             }
        }
        
        var isImplemented: Bool {
            return true
        }
    }
    
    @Published var renderScale: RenderScale = .native
    @Published var scalingType: ScalingType = .off
    @Published var qualityMode: QualityMode = .ultra
    @Published var scaleFactor: ScaleFactorOption = .x1
    @Published var frameGenMode: FrameGenMode = .off
    @Published var frameGenType: FrameGenType = .adaptive
    @Published var targetFPS: TargetFPS = .fps120
    @Published var frameGenMultiplier: FrameGenMultiplier = .x2
    @Published var aaMode: AAMode = .off
    @Published var captureCursor: Bool = true
    @Published var reduceLatency: Bool = true
    @Published var adaptiveSync: Bool = true
    @Published var showMGHUD: Bool = true
    @Published var vsync: Bool = true
    @Published var sharpening: Float = 0.5
    @Published var motionScale: Float = 1.0
    
    var effectiveUpscaleFactor: Float {
        guard scalingType != .off else { return 1.0 }
        return scaleFactor.floatValue / renderScale.multiplier
    }
    
    var isUpscalingEnabled: Bool { scalingType != .off }
    var isFrameGenEnabled: Bool { frameGenMode != .off }
    var outputMultiplier: Float { isUpscalingEnabled ? scaleFactor.floatValue : 1.0 }
    
    var interpolatedFrameCount: Int {
        guard isFrameGenEnabled else { return 1 }
        return frameGenMultiplier.intValue
    }
    
    var effectiveTargetFPS: Int {
        guard isFrameGenEnabled else { return 60 }
        switch frameGenType {
        case .adaptive: return targetFPS.intValue
        case .fixed: return 60 * frameGenMultiplier.intValue
        }
    }
    
    func calculateAdaptiveMultiplier(sourceFPS: Float) -> Int {
        guard frameGenType == .adaptive, sourceFPS > 0 else { return frameGenMultiplier.intValue }
        let needed = Float(targetFPS.intValue) / sourceFPS
        return max(1, min(4, Int(ceil(needed))))
    }
    
    func saveProfile(_ name: String) {
        let defaults = UserDefaults.standard
        let prefix = "PeachScaling.Profile.\(name)."
        
        defaults.set(renderScale.rawValue, forKey: prefix + "renderScale")
        defaults.set(scalingType.rawValue, forKey: prefix + "scalingType")
        defaults.set(qualityMode.rawValue, forKey: prefix + "qualityMode")
        defaults.set(scaleFactor.rawValue, forKey: prefix + "scaleFactor")
        defaults.set(frameGenMode.rawValue, forKey: prefix + "frameGenMode")
        defaults.set(frameGenType.rawValue, forKey: prefix + "frameGenType")
        defaults.set(targetFPS.rawValue, forKey: prefix + "targetFPS")
        defaults.set(frameGenMultiplier.rawValue, forKey: prefix + "frameGenMultiplier")
        defaults.set(aaMode.rawValue, forKey: prefix + "aaMode")
        defaults.set(captureCursor, forKey: prefix + "captureCursor")
        defaults.set(reduceLatency, forKey: prefix + "reduceLatency")
        defaults.set(adaptiveSync, forKey: prefix + "adaptiveSync")
        defaults.set(showMGHUD, forKey: prefix + "showMGHUD")
        defaults.set(vsync, forKey: prefix + "vsync")
        defaults.set(sharpening, forKey: prefix + "sharpening")
        
        if !profiles.contains(name) {
            profiles.append(name)
            defaults.set(profiles, forKey: "PeachScaling.Profiles")
        }
    }
    
    func loadProfile(_ name: String) {
        let defaults = UserDefaults.standard
        let prefix = "PeachScaling.Profile.\(name)."
        
        if let rs = defaults.string(forKey: prefix + "renderScale"), let val = RenderScale(rawValue: rs) { renderScale = val }
        if let st = defaults.string(forKey: prefix + "scalingType"), let val = ScalingType(rawValue: st) { scalingType = val }
        if let qm = defaults.string(forKey: prefix + "qualityMode"), let val = QualityMode(rawValue: qm) { qualityMode = val }
        if let sf = defaults.string(forKey: prefix + "scaleFactor"), let val = ScaleFactorOption(rawValue: sf) { scaleFactor = val }
        if let fg = defaults.string(forKey: prefix + "frameGenMode"), let val = FrameGenMode(rawValue: fg) { frameGenMode = val }
        if let ft = defaults.string(forKey: prefix + "frameGenType"), let val = FrameGenType(rawValue: ft) { frameGenType = val }
        if let tf = defaults.string(forKey: prefix + "targetFPS"), let val = TargetFPS(rawValue: tf) { targetFPS = val }
        if let fm = defaults.string(forKey: prefix + "frameGenMultiplier"), let val = FrameGenMultiplier(rawValue: fm) { frameGenMultiplier = val }
        if let aa = defaults.string(forKey: prefix + "aaMode"), let val = AAMode(rawValue: aa) { aaMode = val }
        
        if defaults.object(forKey: prefix + "captureCursor") != nil { captureCursor = defaults.bool(forKey: prefix + "captureCursor") }
        if defaults.object(forKey: prefix + "reduceLatency") != nil { reduceLatency = defaults.bool(forKey: prefix + "reduceLatency") }
        if defaults.object(forKey: prefix + "adaptiveSync") != nil { adaptiveSync = defaults.bool(forKey: prefix + "adaptiveSync") }
        if defaults.object(forKey: prefix + "showMGHUD") != nil { showMGHUD = defaults.bool(forKey: prefix + "showMGHUD") }
        if defaults.object(forKey: prefix + "vsync") != nil { vsync = defaults.bool(forKey: prefix + "vsync") }
        if defaults.object(forKey: prefix + "sharpening") != nil {
            sharpening = max(0.0, min(1.0, defaults.float(forKey: prefix + "sharpening")))
        }
        
        selectedProfile = name
    }
    
    func deleteProfile(_ name: String) {
        guard name != "Default" else { return }
        profiles.removeAll { $0 == name }
        
        let defaults = UserDefaults.standard
        defaults.set(profiles, forKey: "PeachScaling.Profiles")
        
        let prefix = "PeachScaling.Profile.\(name)."
        let keys = ["renderScale", "scalingType", "qualityMode", "scaleFactor",
                    "frameGenMode", "frameGenType", "targetFPS", "frameGenMultiplier", "aaMode",
                    "captureCursor", "reduceLatency", "adaptiveSync",
                    "showMGHUD", "vsync", "sharpening"]
        keys.forEach { defaults.removeObject(forKey: prefix + $0) }
    }
    
    init() {
        if let savedProfiles = UserDefaults.standard.array(forKey: "PeachScaling.Profiles") as? [String] {
            profiles = savedProfiles
        }
        loadProfile("Default")
    }
}
