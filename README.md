## Quick Links

[Features](#features) • [Requirements](#requirements) • [Usage](#usage) • [Troubleshooting](#troubleshooting)

---

# PeachScaling

GPU-accelerated frame scaling and interpolation for macOS

A macOS port of Lossless Scaling technology, bringing advanced upscaling and frame generation to any application running on your Mac.

> ⚠️ **Active Development**: This project is under active development and may be incomplete or unstable.

![macOS](https://img.shields.io/badge/macOS-15.0+-blue) ![Swift](https://img.shields.io/badge/Swift-5.9+-orange) ![Metal](https://img.shields.io/badge/Metal-3.0+-red)

---

# ✨ Features

### Upscaling

| Mode | Description |
|------|-------------|
| MGUP-1 | MetalFX-powered spatial AI upscaling |
| MGUP-1 Fast | Bilinear interpolation with adaptive sharpening |
| MGUP-1 Quality | Premium MetalFX with Contrast Adaptive Sharpening (CAS) |

- **Scale Factors**: 1.0x to 10.0x
- **Render Scale**: 33% to 100% for GPU optimization

### Frame Generation (MGFG-1)

- **Optical Flow Interpolation**: Generate intermediate frames for smoother motion
- **Adaptive Mode**: Automatically adjusts to target FPS (60-360Hz)
- **Fixed Mode**: 2x, 3x, or 4x frame multiplication
- **Low Latency**: Optimized compute submission and pacing

### Anti-Aliasing

| Mode | Type | Best For |
|------|------|----------|
| FXAA | Fast Approximate | Performance-focused scenarios |
| SMAA | Subpixel Morphological | Balanced quality and speed |
| TAA | Temporal | Best quality with motion vectors |

### Additional Features

- Real-time HUD with performance metrics
- Per-window capture and scaling
- Hotkey support (Cmd+Shift+T to toggle)
- Profile system for different use cases
- VSync and adaptive sync support
- Cursor capture toggle

---

## 📋 Requirements

### System

- **macOS**: 15.0 (Sequoia) or later
- **VRAM**: 4GB+ recommended for 4K+ upscaling

### GPU (MetalFX-capable)

| Platform | Supported GPUs |
|----------|----------------|
| Apple Silicon | M1, M2, M3 (any variant) |
| Intel | HD 5000+ with Metal support |
| AMD | GCN-based or newer with Metal 3 |

### Permissions

- **Accessibility**: Window tracking
- **Screen Recording**: Application capture

---

## 🎮 Usage

### Quick Start

1. Launch PeachScaling
2. Grant required permissions when prompted
3. Click **START SCALING**
4. Switch to your target application within 5 seconds
5. Enjoy enhanced visuals!

### Hotkeys

| Key | Action |
|-----|--------|
| Cmd+Shift+T | Toggle scaling on/off |

---

# 🏗️ Architecture

PeachScaling is built entirely in pure Swift with Metal and MetalFX, leveraging:

- **ScreenCaptureKit**: Modern macOS screen capture API
- **MetalFX**: Apple hardware-accelerated upscaling
- **Metal Compute Shaders**: Custom kernels for frame interpolation and anti-aliasing
- **Swift Concurrency**: Safe async/await patterns for frame processing

---

## 🔧 Troubleshooting

### Black screen after starting

- Ensure Screen Recording permission is granted in System Preferences → Privacy
- Restart PeachScaling after granting permissions

### Low FPS

- Reduce Render Scale percentage
- Disable Frame Generation for latency-sensitive applications
- Check that your Mac isn't running on battery

### TAA ghosting

- TAA works best with consistent motion
- Consider SMAA or FXAA for fast camera movements

---

## 📄 License

MIT License - See LICENSE file for details
