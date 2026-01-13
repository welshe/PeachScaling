import SwiftUI
import MetalKit
import ApplicationServices

let BG_COLOR = Color(red: 0.1, green: 0.1, blue: 0.12)
let PANEL_COLOR = Color(red: 0.15, green: 0.15, blue: 0.18)
let ACCENT_RED = Color(red: 0.8, green: 0.2, blue: 0.2)
let TEXT_COLOR = Color.white.opacity(0.9)

@available(macOS 15.0, *)
struct ContentView: View {

    @StateObject var settings = CaptureSettings()

    @State private var countdown = 5
    @State private var isCountingDown = false
    @State private var isScalingActive = false
    @State private var countdownTimer: Timer?

    @State private var directRenderer: DirectRenderer?

    @State private var connectedProcessName: String = "-"
    @State private var connectedPID: Int32 = 0
    @State private var connectedWindowID: CGWindowID = 0
    @State private var connectedSize: CGSize = .zero

    @State private var showAlert = false
    @State private var alertMessage = ""

    @State private var currentFPS: Float = 0.0
    @State private var interpolatedFPS: Float = 0.0
    @State private var processingTime: Double = 0.0

    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var recGranted: Bool = CGPreflightScreenCaptureAccess()

    @State private var permTimer: Timer?

    private var permissionsGranted: Bool { axGranted && recGranted }

    @State private var targetDisplayID: CGDirectDisplayID?

    @State private var statsTimer: Timer?

    @State private var hotkeyMonitor: Any?
    @State private var localHotkeyMonitor: Any?

    @State private var hudController = MGHUDWindowController()

    private var macOSVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                sidebarView
                mainSettingsScrollView
            }
            versionFooter
        }
        .onAppear {
            startPermissionTimer()
            initializeDirectRenderer()
            setupHotkeys()
        }
        .onDisappear {
            permTimer?.invalidate()
            statsTimer?.invalidate()
            countdownTimer?.invalidate()
            if let monitor = hotkeyMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let local = localHotkeyMonitor {
                NSEvent.removeMonitor(local)
            }
        }
        .onChange(of: settings.vsync) { updateRendererConfig() }
        .onChange(of: settings.scaleFactor) { updateRendererConfig() }
        .onChange(of: settings.scalingType) { updateRendererConfig() }
        .onChange(of: settings.frameGenMode) { updateRendererConfig() }
        .onChange(of: settings.aaMode) { updateRendererConfig() }
        .onChange(of: settings.renderScale) { updateRendererConfig() }
        .onChange(of: settings.sharpening) { updateRendererConfig() }
        .onChange(of: settings.showMGHUD) {
            if settings.showMGHUD && isScalingActive {
                hudController.show(compact: false)
            } else {
                hudController.hide()
            }
        }
        .frame(width: 900, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            stop()
        }
        .alert("PeachScaling", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 12) {

                Text("Scaling Info")
                    .font(.headline)
                    .padding([.top, .horizontal])

                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Status", value: isScalingActive ? "Active" : "Idle")
                    InfoRow(label: "FPS", value: currentFPS > 0 ? String(format: "%.1f", currentFPS) : "-")

                    if interpolatedFPS > currentFPS {
                        InfoRow(label: "Interp FPS", value: String(format: "%.1f", interpolatedFPS))
                    }

                    InfoRow(label: "Latency", value: processingTime > 0 ? String(format: "%.2f ms", processingTime) : "-")

                    InfoRow(label: "Process", value: connectedProcessName)
                    InfoRow(label: "PID", value: String(connectedPID))
                    InfoRow(label: "Window ID", value: String(connectedWindowID))

                    InfoRow(label: "Frame",
                            value: connectedSize.width > 0 ?
                                   "\(Int(connectedSize.width)) x \(Int(connectedSize.height))" : "-")

                    InfoRow(label: "Display ID",
                            value: targetDisplayID.map { String($0) } ?? "-")
                }
                .padding(.horizontal)
                .padding(.bottom)

                Spacer()

                HStack {
                    Spacer()
                    Menu {
                        Button("About") {
                            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                            let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
                            alertMessage = "PeachScaling v\(v) (\(b))\n\nA macOS port of Lossless Scaling\nGPU-accelerated frame scaling"
                            showAlert = true
                        }
                        Button("Check for Updates") {
                            alertMessage = "You're running the latest version."
                            showAlert = true
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                .padding()
            }
        }
        .frame(width: 200)
        .background(Color.black.opacity(0.3))
        .disabled(!permissionsGranted)
    }

    @ViewBuilder
    private var mainSettingsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                if !permissionsGranted {
                    PermissionBanner(
                        axGranted: axGranted,
                        recGranted: recGranted,
                        requestAX: {
                            let opts = [
                                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                            ] as CFDictionary
                            AXIsProcessTrustedWithOptions(opts)
                        },
                        requestREC: {
                            _ = CGRequestScreenCaptureAccess()
                        }
                    )
                    .padding(.bottom, 8)
                }

                HStack {
                    Text("Profile: \"Default\"")
                        .font(.largeTitle).bold()
                    Spacer()

                    if isScalingActive {
                        Button("STOP SCALING") { stop() }
                            .buttonStyle(ActionButtonStyle(color: .red))

                    } else if isCountingDown {
                        Text("\(countdown)")
                            .font(.title2)
                            .foregroundColor(ACCENT_RED)

                    } else {
                        Button("START SCALING") { startCountdown() }
                            .buttonStyle(ActionButtonStyle(color: .green))
                            .disabled(!permissionsGranted)
                            .opacity(permissionsGranted ? 1.0 : 0.5)
                    }
                }
                .padding(.bottom, 10)

                settingsConfigGrid
            }
            .padding(24)
        }
        .background(BG_COLOR)
    }

    @ViewBuilder
    private var settingsConfigGrid: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 16) {
                ConfigPanel(title: "Upscaling") {
                    PickerRow(label: "Method",
                              selection: $settings.scalingType,
                              helpText: "Upscaling mode:\n• Off: No upscaling\n• MGUP-1 / Fast / Quality")

                    if settings.scalingType != .off {
                        PickerRow(label: "Scale Factor",
                                  selection: $settings.scaleFactor,
                                  helpText: "Upscale multiplier (1.5x – 10x).")

                        PickerRow(label: "Render Scale",
                                  selection: $settings.renderScale,
                                  helpText: "Internal capture resolution %.")
                    }
                }

                ConfigPanel(title: "Frame Generation") {
                    PickerRow(label: "Mode",
                              selection: $settings.frameGenMode,
                              helpText: "• Off: lowest latency\n• MGFG-1: optical-flow generation")

                    if settings.frameGenMode != .off {
                        Text(settings.frameGenMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)

                        PickerRow(label: "Type",
                                  selection: $settings.frameGenType,
                                  helpText: "• Adaptive: auto-adjusts to target FPS\n• Fixed: manual multiplier")

                        if settings.frameGenType == .adaptive {
                            PickerRow(label: "Target FPS",
                                      selection: $settings.targetFPS,
                                      helpText: "Target frame rate for adaptive generation.")
                        } else {
                            PickerRow(label: "Multiplier",
                                      selection: $settings.frameGenMultiplier,
                                      helpText: "2× / 3× / 4× frame multiplication.")
                        }

                        ToggleRow(label: "Reduce Latency",
                                  isOn: $settings.reduceLatency,
                                  helpText: "Optimized pacing & compute submission.")
                    }
                }

                ConfigPanel(title: "Anti-Aliasing") {
                    PickerRow(label: "Mode",
                              selection: $settings.aaMode,
                              helpText: "• FXAA\n• SMAA\n• MSAA\n• TAA")

                    if settings.aaMode != .off {
                        Text(settings.aaMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 16) {
                if settings.scalingType == .mgup1 || settings.scalingType == .mgup1Quality {
                    ConfigPanel(title: "MGUP-1 Settings") {
                        PickerRow(label: "Quality",
                                  selection: $settings.qualityMode,
                                  helpText: "MetalFX color processing + CAS")

                        Text("Using MetalFX Spatial AI Upscaling")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ConfigPanel(title: "Display Settings") {
                    ToggleRow(label: "Show MG HUD",
                              isOn: $settings.showMGHUD,
                              helpText: "Performance overlay")

                    ToggleRow(label: "Capture Cursor",
                              isOn: $settings.captureCursor,
                              helpText: "Include mouse cursor")

                    ToggleRow(label: "VSync",
                              isOn: $settings.vsync,
                              helpText: "Sync to display refresh")

                    ToggleRow(label: "Adaptive Sync",
                              isOn: $settings.adaptiveSync,
                              helpText: "Automatically adjust output pacing")

                    SliderRow(label: "Sharpness",
                              value: $settings.sharpening,
                              range: 0...1,
                              helpText: "CAS intensity")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!permissionsGranted)
        .opacity(permissionsGranted ? 1.0 : 0.5)
    }

    private var versionFooter: some View {
        Text(macOSVersionString)
            .font(.caption2)
            .foregroundColor(.gray.opacity(0.5))
            .padding(6)
    }

    private func initializeDirectRenderer() {
        guard directRenderer == nil else { return }
        
        guard let renderer = DirectRenderer() else {
            alertMessage = "Failed to initialize rendering engine. Please check that Metal is supported."
            showAlert = true
            return
        }
        
        directRenderer = renderer
        renderer.onWindowLost = {
            Task { @MainActor in
                stop()
                alertMessage = "Target window was closed or became unavailable."
                showAlert = true
            }
        }
        renderer.onWindowMoved = { frame in
            Task { @MainActor in
                connectedSize = frame.size
            }
        }
    }
    
    private func updateRendererConfig() {
        guard let renderer = directRenderer, isScalingActive else { return }
        
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let userScale = CGFloat(settings.scaleFactor.floatValue)
        let sourceSize = connectedSize
        let outputSize = CGSize(
            width: sourceSize.width * userScale * scale,
            height: sourceSize.height * userScale * scale
        )
        
        renderer.configure(
            from: settings,
            targetFPS: settings.effectiveTargetFPS,
            sourceSize: sourceSize,
            outputSize: outputSize
        )
    }

    private func setupHotkeys() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "t" {
                Task { @MainActor in toggleScaling() }
            }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "t" {
                Task { @MainActor in toggleScaling() }
                return event
            }
            return event
        }
    }

    private func toggleScaling() {
        guard permissionsGranted else { return }
        if isScalingActive { stop() }
        else { startDirectCapture() }
    }

    private func startPermissionTimer() {
        permTimer?.invalidate()
        // Reduced frequency and check activity to save resources
        permTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard NSApp.isActive else { return }
            axGranted = AXIsProcessTrusted()
            recGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.statsUpdateInterval, repeats: true) { [self] _ in
            Task { @MainActor in
                guard let renderer = directRenderer else { return }
                
                // Always update basic FPS state for UI (optional, but good for main window)
                currentFPS = renderer.currentFPS
                interpolatedFPS = renderer.interpolatedFPS
                processingTime = renderer.processingTime
                
                // Only do heavy stats retrieval/HUD update if visible
                if settings.showMGHUD {
                    let stats = renderer.getStats()
                    hudController.update(stats: stats, settings: settings)
                }
            }
        }
    }

    private func startCountdown() {
        isCountingDown = true
        countdown = 5
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] timer in
            if countdown > 1 { 
                countdown -= 1 
            } else {
                timer.invalidate()
                countdownTimer = nil
                isCountingDown = false
                startDirectCapture()
            }
        }
    }
    
    private func startDirectCapture() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else {
            alertMessage = "Please switch to the target window before the countdown ends."
            showAlert = true
            return
        }

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        // Helper to parse bounds robustly
        let parseBounds: ([String: Any]) -> CGRect? = { dict in
            let parseValue: (String) -> CGFloat? = { key in
                if let val = dict[key] as? CGFloat { return val }
                if let val = dict[key] as? Int { return CGFloat(val) }
                return nil
            }
            guard let x = parseValue("X"), let y = parseValue("Y"),
                  let w = parseValue("Width"), let h = parseValue("Height") else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }

        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]],
              let targetInfo = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }),
              let wid = targetInfo[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = targetInfo[kCGWindowBounds as String] as? [String: Any],
              let frame = parseBounds(boundsDict) else {
            alertMessage = "Target window not found. Ensure the window is visible."
            showAlert = true
            return
        }

        guard let screen = NSScreen.main else { return }
        let screenH = screen.frame.height

        let nsRect = CGRect(
            x: frame.origin.x,
            y: screenH - (frame.origin.y + frame.height),
            width: frame.width,
            height: frame.height
        )

        updateDisplayID(for: nsRect)

        if directRenderer == nil { initializeDirectRenderer() }
        guard let renderer = directRenderer else {
            alertMessage = "DirectRenderer failed to initialize."
            showAlert = true
            return
        }

        let outputFrame = resolvedDisplayFrame(for: nsRect)
        
        let scale = screen.backingScaleFactor
        let userScale = CGFloat(settings.scaleFactor.floatValue)
        
        let sourceSize = nsRect.size
        
        let outputSize = CGSize(
            width: sourceSize.width * userScale * scale,
            height: sourceSize.height * userScale * scale
        )

        renderer.configure(
            from: settings,
            targetFPS: settings.effectiveTargetFPS,
            sourceSize: sourceSize,
            outputSize: outputSize
        )

        renderer.attachToScreen(screen, size: sourceSize, windowFrame: nsRect)

        if renderer.startCapture(windowID: wid, pid: app.processIdentifier) {
            connectedProcessName = app.localizedName ?? "Unknown"
            connectedPID = app.processIdentifier
            connectedWindowID = wid
            connectedSize = nsRect.size

            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()

            isScalingActive = true
            startStatsTimer()

            if settings.showMGHUD {
                hudController.show(compact: false)
                if let device = MTLCreateSystemDefaultDevice() {
                    hudController.setDeviceName(device.name)
                }
                hudController.setResolutions(capture: nsRect.size, output: outputFrame.size)
            }

        } else {
            alertMessage = "Failed to start capture. Make sure you have Screen Recording permission."
            showAlert = true
            renderer.detachWindow()
            // Restore activation policy on failure
            NSApp.setActivationPolicy(.regular)
        }
    }

    func stop() {
        directRenderer?.stopCapture()
        directRenderer?.detachWindow()
        statsTimer?.invalidate()
        statsTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        hudController.hide()
        isScalingActive = false
        currentFPS = 0.0
        interpolatedFPS = 0.0
        processingTime = 0.0
        connectedProcessName = "-"
        connectedPID = 0
        connectedWindowID = 0
        connectedSize = .zero
        targetDisplayID = nil
        NSApp.setActivationPolicy(.regular)
    }

    private func updateDisplayID(for frame: CGRect) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            targetDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
    }

    private func resolvedDisplayFrame(for sourceFrame: CGRect) -> CGRect {
        let center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return screen.frame
        }
        return NSScreen.main?.frame ?? sourceFrame
    }
}

struct ConfigPanel<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.title3).bold().foregroundColor(.white)
            Divider().background(Color.gray)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PANEL_COLOR)
        .cornerRadius(10)
    }
}

struct PickerRow<T: Hashable & Identifiable & RawRepresentable & CaseIterable>: View where T.RawValue == String {
    let label: String
    @Binding var selection: T
    var helpText: String? = nil
    var body: some View {
        let row = HStack {
            Text(label).foregroundColor(.gray)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(Array(T.allCases), id: \.id) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .frame(minWidth: 160, maxWidth: 220)
        }
        if let helpText { row.help(helpText) } else { row }
    }
}

struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var helpText: String? = nil
    var body: some View {
        let row = HStack {
            Text(label).foregroundColor(.gray)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
        if let helpText { row.help(helpText) } else { row }
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var helpText: String? = nil
    var body: some View {
        let row = HStack {
            Text(label).foregroundColor(.gray)
            Spacer()
            Slider(value: $value, in: range)
                .frame(width: 120)
            Text(String(format: "%.2f", value))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 40, alignment: .trailing)
        }
        if let helpText { row.help(helpText) } else { row }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.gray)
            Spacer()
            Text(value)
                .foregroundColor(.white)
                .font(.system(.body, design: .monospaced))
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .frame(minWidth: 120)
            .frame(height: 36)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1.0))
            .foregroundColor(.white)
            .cornerRadius(8)
            .fontWeight(.bold)
    }
}

struct PermissionBanner: View {
    let axGranted: Bool
    let recGranted: Bool
    let requestAX: () -> Void
    let requestREC: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StatusPill(label: "Accessibility", ok: axGranted, action: requestAX)
                StatusPill(label: "Screen Recording", ok: recGranted, action: requestREC)
                Spacer()
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.15))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.4), lineWidth: 1))
        .cornerRadius(8)
    }
}

struct StatusPill: View {
    let label: String
    let ok: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(ok ? "[ PASS ]" : "[ REQUIRED ]")
                .foregroundColor(ok ? .green : .orange)
                .font(.system(.caption, design: .monospaced))
            Text(label)
                .foregroundColor(.white)
                .font(.caption)
            if !ok {
                Button("GRANT") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.4))
        .cornerRadius(6)
    }
}
