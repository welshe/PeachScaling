import Foundation
import Metal

enum AppConstants {
    // Texture limits
    static let maxTextureSizeApple = 16384
    static let maxTextureSizeDefault = 8192
    
    // Ring Buffer
    static let ringBufferCapacity = 5
    
    // Stream config
    static let streamTimeScale: Int32 = 60
    static let displayLinkPreferredFPS = 120
    
    // Stats
    static let statsUpdateInterval: TimeInterval = 0.25
    
    // Metal Threadgroups
    static let threadgroupSize = 16
    static let motionThreadgroupSize = 8
    
    // AA Constants
    static let taaModulation: Float = 0.1
    static let aaThreshold: Float = 0.1
    static let aaSubpixelBlend: Float = 0.75
    
    // Hotkeys
    static let defaultHotkeyCharacter = "t"
}
