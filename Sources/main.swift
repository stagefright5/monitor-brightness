import AppKit
import Darwin
import ServiceManagement
import Combine
import QuartzCore

struct Monitor: Identifiable, Equatable {
    let id: String
    let name: String
}

struct BrightnessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum DDC {
    static let queue = DispatchQueue(label: "local.monitor-brightness.ddc")
    static var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/m1ddc")
    }

    static func parseDisplays(_ output: String) -> [Monitor] {
        let pattern = #"^\[\d+\] (.+) \(([A-Fa-f0-9-]{36})\)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return output.components(separatedBy: .newlines).compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let name = Range(match.range(at: 1), in: line),
                  let id = Range(match.range(at: 2), in: line) else { return nil }
            return Monitor(id: String(line[id]), name: String(line[name]))
        }
    }

    static func runSync(_ arguments: [String], executable: URL = executable) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw BrightnessError(message: "The monitor did not respond. Check its connection and try Refresh.")
        }
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw BrightnessError(message: "Couldn’t communicate with this monitor. Enable DDC/CI in its on-screen menu, then try Refresh.")
        }
        return result
    }

    static func run(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try runSync(arguments)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func read(_ monitor: Monitor, maximum: Bool = false) async throws -> Int {
        let value = try await run(["display", monitor.id, maximum ? "max" : "get", "luminance"])
        guard let number = Int(value), (0...65535).contains(number), !maximum || number > 0 else {
            throw BrightnessError(message: "This monitor didn’t report a valid brightness value.")
        }
        return number
    }
}

@MainActor
final class BrightnessModel: ObservableObject {
    @Published var monitors: [Monitor] = []
    @Published var selectedID = ""
    @Published var brightness = 0.0
    @Published var ready = false
    @Published var loading = false
    @Published var applying = false
    @Published var error: String?
    private var maximum = 100
    private var revision = 0
    private var pending: Task<Void, Never>?
    var selected: Monitor? { monitors.first { $0.id == selectedID } }

    func refresh() {
        pending?.cancel()
        revision += 1
        let currentRevision = revision
        ready = false
        loading = true
        applying = false
        error = nil
        Task {
            do {
                let all = DDC.parseDisplays(try await DDC.run(["display", "list"]))
                // Only offer displays that actually support hardware brightness reads.
                var supported: [Monitor] = []
                for monitor in all {
                    if let _ = try? await DDC.read(monitor) { supported.append(monitor) }
                }
                guard revision == currentRevision else { return }
                monitors = supported
                guard !supported.isEmpty else {
                    throw BrightnessError(message: "No compatible monitor found. Check the cable and enable DDC/CI in the monitor’s on-screen menu.")
                }
                let preferred = selectedID.isEmpty ? UserDefaults.standard.string(forKey: "display") : selectedID
                selectedID = supported.first { $0.id == preferred }?.id ?? supported[0].id
                try await loadSelection(currentRevision)
            } catch {
                guard revision == currentRevision else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func select(_ id: String) {
        selectedID = id
        pending?.cancel()
        revision += 1
        let currentRevision = revision
        ready = false
        loading = true
        applying = false
        error = nil
        Task {
            do { try await loadSelection(currentRevision) }
            catch {
                guard revision == currentRevision else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func loadSelection(_ currentRevision: Int) async throws {
        guard let monitor = selected else { return }
        let maxValue = try await DDC.read(monitor, maximum: true)
        let value = try await DDC.read(monitor)
        guard revision == currentRevision else { return }
        guard value <= maxValue else { throw BrightnessError(message: "The monitor reported an invalid brightness range.") }
        maximum = maxValue
        brightness = Double(value) / Double(maxValue) * 100
        ready = true
        loading = false
        UserDefaults.standard.set(monitor.id, forKey: "display")
    }

    func setBrightness(_ percent: Double) {
        guard ready, let monitor = selected else { return }
        brightness = min(100, max(0, percent))
        pending?.cancel()
        revision += 1
        let currentRevision = revision
        let value = Int((brightness / 100 * Double(maximum)).rounded())
        applying = true
        error = nil
        pending = Task {
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                try Task.checkCancellation()
                _ = try await DDC.run(["display", monitor.id, "set", "luminance", String(value)])
                try Task.checkCancellation()
                let actual = try await DDC.read(monitor)
                guard revision == currentRevision else { return }
                brightness = Double(actual) / Double(maximum) * 100
                applying = false
                if abs(actual - value) > 1 {
                    error = "The monitor kept a different brightness. Check whether its picture mode locks brightness."
                }
            } catch is CancellationError {
                // A newer slider position replaces this request.
            } catch {
                guard revision == currentRevision else { return }
                self.error = error.localizedDescription
                applying = false
                ready = false
            }
        }
    }
}

@MainActor
final class LoginSettings: ObservableObject {
    @Published var enabled = false
    @Published var needsApproval = false
    @Published var error: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func configureOnFirstLaunch() {
        refresh()
        guard !UserDefaults.standard.bool(forKey: "loginConfigured") else { return }
        // Register the installed copy, never a temporary build or test bundle.
        guard Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else {
            error = "Move the app to Applications to enable launch at login."
            return
        }
        setEnabled(true)
    }

    func setEnabled(_ value: Bool) {
        error = nil
        if value && Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent != "Applications" {
            error = "Move the app to Applications to enable launch at login."
            refresh()
            return
        }
        do {
            if value && SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !value && SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(true, forKey: "loginConfigured")
        } catch {
            self.error = "Couldn't change launch at login: \(error.localizedDescription)"
        }
        refresh()
    }
}

@MainActor
final class BrightnessView: NSVisualEffectView {
    private let model: BrightnessModel
    private let login: LoginSettings
    private let monitorName = NSTextField(labelWithString: "External display")
    private let valueLabel = NSTextField(labelWithString: "—%")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Connecting to monitor…")
    private let loginError = NSTextField(wrappingLabelWithString: "")
    private let monitorPicker = NSPopUpButton()
    private let refreshButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let approvalButton = NSButton(title: "Allow in Login Items settings…", target: nil, action: nil)
    private var presets: [NSButton] = []
    private var subscriptions = Set<AnyCancellable>()
    private var renderQueued = false
    var onLayout: (() -> Void)?

    init(model: BrightnessModel, login: LoginSettings) {
        self.model = model
        self.login = login
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 370),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22)
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
            let result = NSStackView(views: views)
            result.orientation = .horizontal
            result.alignment = .centerY
            result.spacing = spacing
            return result
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return view
        }
        func symbol(_ name: String) -> NSImageView {
            let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!)
            image.contentTintColor = .secondaryLabelColor
            image.widthAnchor.constraint(equalToConstant: 18).isActive = true
            return image
        }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = NSTextField(labelWithString: "Monitor Brightness")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        monitorName.font = .systemFont(ofSize: 11)
        monitorName.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, monitorName])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh monitors")
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Refresh connected monitors"
        refreshButton.setAccessibilityLabel("Refresh monitors")
        add(row([icon, labels, spacer(), refreshButton]))

        monitorPicker.target = self
        monitorPicker.action = #selector(selectMonitor)
        monitorPicker.setAccessibilityLabel("Monitor")
        add(monitorPicker)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 60, weight: .light)
        valueLabel.alignment = .center
        add(valueLabel)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(adjustBrightness)
        slider.setAccessibilityLabel("Monitor brightness")
        add(row([symbol("sun.min"), slider, symbol("sun.max.fill")]))
        presets = [25, 50, 75, 100].map { value in
            let button = NSButton(title: "\(value)%", target: self, action: #selector(preset))
            button.tag = value
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setAccessibilityLabel("Set brightness to \(value) percent")
            return button
        }
        let presetRow = row(presets)
        presetRow.distribution = .fillEqually
        add(presetRow)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.preferredMaxLayoutWidth = 322
        add(statusLabel)
        let divider = NSBox()
        divider.boxType = .separator
        add(divider)
        let loginLabel = NSTextField(labelWithString: "Launch at login")
        loginLabel.font = .systemFont(ofSize: 11)
        loginSwitch.controlSize = .mini
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        loginSwitch.setAccessibilityLabel("Launch at login")
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.isBordered = false
        quit.contentTintColor = .controlAccentColor
        quit.font = .systemFont(ofSize: 11)
        add(row([loginLabel, loginSwitch, spacer(), quit], spacing: 8))
        approvalButton.isBordered = false
        approvalButton.contentTintColor = .controlAccentColor
        approvalButton.font = .systemFont(ofSize: 11)
        approvalButton.target = self
        approvalButton.action = #selector(openLoginSettings)
        add(approvalButton)
        loginError.font = .systemFont(ofSize: 11)
        loginError.textColor = .systemOrange
        loginError.preferredMaxLayoutWidth = 322
        add(loginError)
        for publisher in [model.objectWillChange, login.objectWillChange] {
            publisher.sink { [weak self] _ in
                guard let self, !self.renderQueued else { return }
                self.renderQueued = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.renderQueued = false
                    self.render()
                    self.onLayout?()
                }
            }.store(in: &subscriptions)
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        monitorName.stringValue = model.selected?.name ?? "External display"
        valueLabel.stringValue = model.ready ? "\(Int(model.brightness.rounded()))%" : "—%"
        slider.doubleValue = model.brightness
        slider.isEnabled = model.ready
        presets.forEach { $0.isEnabled = model.ready }
        refreshButton.isEnabled = !model.loading && !model.applying
        monitorPicker.isHidden = model.monitors.count < 2
        if monitorPicker.itemTitles != model.monitors.map(\.name) {
            monitorPicker.removeAllItems()
            monitorPicker.addItems(withTitles: model.monitors.map(\.name))
        }
        if let index = model.monitors.firstIndex(where: { $0.id == model.selectedID }) {
            monitorPicker.selectItem(at: index)
        }
        monitorPicker.isEnabled = !model.loading && !model.applying
        statusLabel.stringValue = model.error ?? (model.loading ? "Connecting to monitor…" : model.applying ? "Adjusting brightness…" : "Hardware brightness · Connected")
        statusLabel.textColor = model.error == nil ? .secondaryLabelColor : .systemOrange
        loginSwitch.state = login.enabled ? .on : .off
        approvalButton.isHidden = !login.needsApproval
        loginError.stringValue = login.error ?? ""
        loginError.isHidden = login.error == nil
    }

    @objc private func refresh() { model.refresh() }
    @objc private func selectMonitor() {
        let index = monitorPicker.indexOfSelectedItem
        guard model.monitors.indices.contains(index) else { return }
        model.select(model.monitors[index].id)
    }
    @objc private func adjustBrightness() { model.setBrightness(slider.doubleValue.rounded()) }
    @objc private func preset(_ sender: NSButton) { model.setBrightness(Double(sender.tag)) }
    @objc private func toggleLogin() { login.setEnabled(loginSwitch.state == .on) }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// Keep the panel inside its screen and below the menu bar, including screens
// whose coordinate origin is above or below the primary display.
func panelFrame(size: NSSize, anchor: NSRect, visible: NSRect, screen: NSRect, menuBarHeight: CGFloat) -> NSRect {
    let top = min(visible.maxY, screen.maxY - menuBarHeight) - 4
    let x = max(visible.minX + 8, min(anchor.midX - size.width / 2, visible.maxX - size.width - 8))
    return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
}

final class BrightnessPanel: NSPanel {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onEscape?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BrightnessModel()
    let login = LoginSettings()
    var statusItem: NSStatusItem!
    private var panel: BrightnessPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var opening = false
    private var closing = false
    private func trace(_ message: String) {
        if CommandLine.arguments.contains("--debug-ui") {
            NSLog("MonitorBrightness UI: %@", message)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let symbol = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Monitor Brightness")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        symbol?.isTemplate = true
        statusItem.button?.image = symbol
        statusItem.button?.setAccessibilityLabel("Monitor Brightness")
        statusItem.button?.toolTip = "Monitor Brightness"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hidePanel), name: NSApplication.didResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
        login.configureOnFirstLaunch()
    }

    @objc func displaysChanged() {
        // Read hardware only while controls are visible. Opening always rescans.
        if panel?.isVisible == true {
            model.refresh()
            positionPanel()
        }
    }

    private func createPanel() -> BrightnessPanel {
        let content = BrightnessView(model: model, login: login)
        let window = BrightnessPanel(contentRect: .zero, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        window.title = "Monitor Brightness"
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = content
        content.onLayout = { [weak self] in self?.positionPanel() }
        window.onEscape = { [weak self] in self?.hidePanel() }
        return window
    }

    private func targetFrame() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main,
              let content = panel?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return panelFrame(size: content.fittingSize, anchor: anchor, visible: screen.visibleFrame,
                          screen: screen.frame, menuBarHeight: NSStatusBar.system.thickness)
    }

    private func positionPanel() {
        guard !opening, !closing, let frame = targetFrame() else { return }
        panel?.setFrame(frame, display: true)
    }

    private func watchForDismissal() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.trace("Escape received keyWindow=\(panel.isKeyWindow)")
                self.hidePanel()
                return nil
            }
            if event.type != .keyDown && event.window !== panel && event.window !== self.statusItem.button?.window {
                self.hidePanel()
            }
            return event
        }
    }

    @objc func hidePanel() {
        guard let panel, !closing else { return }
        trace("dismiss requested")
        closing = true
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self else { return }
                panel?.orderOut(nil)
                panel?.contentView = nil
                panel?.close()
                self.panel = nil
                self.opening = false
                self.closing = false
                self.trace("dismissed visible=\(panel?.isVisible ?? false) panelReleased=\(self.panel == nil)")
            }
        }
    }

    @objc func togglePanel() {
        if closing { return }
        if panel != nil { hidePanel(); return }
        model.refresh()
        login.refresh()
        let window = createPanel()
        panel = window
        guard let frame = targetFrame() else { panel = nil; return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame.offsetBy(dx: 0, dy: reduceMotion ? 0 : -6), display: false)
        window.alphaValue = 0
        opening = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window)
        watchForDismissal()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.10 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window, self.panel === window else { return }
                self.opening = false
                self.positionPanel()
                if !self.closing {
                    window.makeKey()
                    self.trace("opened visible=\(window.isVisible) keyWindow=\(window.isKeyWindow)")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel == nil { togglePanel() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if CommandLine.arguments.contains("--login-status") {
    switch SMAppService.mainApp.status {
    case .enabled: print("Launch at login: enabled")
    case .requiresApproval: print("Launch at login: requires approval in System Settings")
    case .notRegistered: print("Launch at login: disabled")
    case .notFound: print("Launch at login: app not found")
    @unknown default: print("Launch at login: unknown status")
    }
} else if CommandLine.arguments.contains("--check") {
    do {
        let displays = DDC.parseDisplays(try DDC.runSync(["display", "list"]))
        for display in displays {
            if let value = try? DDC.runSync(["display", display.id, "get", "luminance"]) {
                print("\(display.name): \(value)")
            }
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--test") {
    let sample = "[1] Example Display (11111111-2222-3333-4444-555555555555)\ninvalid\n[2] Display (HDMI) (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)"
    let displays = DDC.parseDisplays(sample)
    precondition(displays.count == 2 && displays[1].name == "Display (HDMI)")
    precondition(DDC.parseDisplays("").isEmpty)
    precondition(DDC.parseDisplays("[1] broken (not-a-uuid)").isEmpty)
    do {
        _ = try DDC.runSync([], executable: URL(fileURLWithPath: "/usr/bin/false"))
        fatalError("A failed process was accepted")
    } catch { print("Process failures handled") }
    do {
        _ = try DDC.runSync(["10"], executable: URL(fileURLWithPath: "/bin/sleep"))
        fatalError("A hung process was accepted")
    } catch { print("Process timeout handled") }
    for screen in [NSRect(x: 0, y: 0, width: 1920, height: 1080),
                   NSRect(x: -1920, y: 1080, width: 1920, height: 1080)] {
        let visible = NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - 24)
        for anchorX in [screen.minX + 12, screen.maxX - 12] {
            let frame = panelFrame(size: NSSize(width: 370, height: 340),
                                   anchor: NSRect(x: anchorX, y: screen.maxY - 24, width: 24, height: 24),
                                   visible: visible, screen: screen, menuBarHeight: 24)
            precondition(frame.maxY == visible.maxY - 4)
            precondition(frame.minX >= visible.minX && frame.maxX <= visible.maxX)
        }
    }
    print("Panel stays below the menu bar and inside either screen edge")
    print("All checks passed")
} else {
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Monitor Brightness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    app.mainMenu = mainMenu
    app.run()
    }
}
