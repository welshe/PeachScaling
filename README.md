**GPU-accelerated frame scaling and interpolation for macOS**

A macOS port of Lossless Scaling technology, bringing advanced upscaling and frame generation to any application running on your Mac.

[ITS STILL IN ACTIVE DEVELOPMENT, IT MIGHT BE FULLY BROKEN AND OR WORKING AT THE TIME YOU DOWNLOAD.]

![macOS](https://img.shields.io/badge/macOS-15.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![Metal](https://img.shields.io/badge/Metal-3.0+-red)
![License](https://img.shields.io/badge/license-MIT-green)

---

## 🚀 Features

### **Upscaling Technologies**
- **MGUP-1**: MetalFX-powered spatial AI upscaling
- **MGUP-1 Fast**: Bilinear interpolation with adaptive sharpening
- **MGUP-1 Quality**: Premium MetalFX with Contrast Adaptive Sharpening (CAS)
- **Scale Factors**: 1.0x to 10.0x
- **Render Scale**: Optimize GPU load by rendering at 33%-100% resolution

### **Frame Generation (MGFG-1)**
- **Optical Flow Interpolation**: Generate intermediate frames for smoother motion
- **Adaptive Mode**: Automatically adjusts to target FPS (60-360Hz)
- **Fixed Mode**: 2x, 3x, or 4x frame multiplication
- **Low Latency**: Optimized compute submission and pacing

### **Anti-Aliasing**
- **FXAA**: Fast approximate anti-aliasing
- **SMAA**: Subpixel morphological anti-aliasing
- **TAA**: Temporal anti-aliasing

### **Additional Features**
- Real-time HUD with performance metrics
- Per-window capture and scaling
- Hotkey support (Cmd+Shift+T to toggle)
- Profile system for different use cases
- VSync and adaptive sync support
- Cursor capture toggle

---

## 📋 Requirements

- **macOS**: 15.0 (Sequoia) or later
- **GPU**: Apple Silicon (M1/M2/M3) or AMD GPU with Metal 3 support
- **Permissions**: 
  - Accessibility (for window tracking)
  - Screen Recording (for capture)

---

## 🎮 Usage

### **Quick Start**

1. Launch PeachScaling
2. Grant required permissions when prompted
3. Click "START SCALING"
4. Switch to your target application within 5 seconds
5. Enjoy enhanced visuals!

### **Hotkeys**

- `Cmd+Shift+T`: Toggle scaling on/off

### **Recommended Settings**

#### For Gaming (60 FPS → 120 FPS)
- **Upscaling**: MGUP-1 Quality, 2.0x
- **Frame Gen**: MGFG-1, Fixed 2x
- **Render Scale**: 67%
- **AA**: FXAA
- **Sharpness**: 0.5-0.7

#### For High Refresh Displays (120Hz+)
- **Upscaling**: MGUP-1 Fast, 1.5x
- **Frame Gen**: MGFG-1, Adaptive 144 FPS
- **Render Scale**: 75%
- **AA**: Off
- **Reduce Latency**: On

#### For Screenshot/Recording Quality
- **Upscaling**: MGUP-1 Quality, 2.0x-3.0x
- **Frame Gen**: Off
- **Render Scale**: Native (100%)
- **Quality Mode**: Ultra
- **Sharpness**: 0.7-0.9

---

## 🏗️ Architecture

PeachScaling is built entirely in **pure Swift** with **Metal** and **MetalFX**, eliminating the C++/Objective-C++ complexity of the original implementation.
