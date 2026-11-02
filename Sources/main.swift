import AppKit
import Darwin
import ServiceManagement
import Combine
import QuartzCore
import SwiftUI

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
    @Published var brightness = UserDefaults.standard.double(forKey: "lastBrightness")
    /// True once any brightness is known, so the panel can show it while re-reading.
    @Published var hasValue = UserDefaults.standard.object(forKey: "lastBrightness") != nil
    @Published var ready = false
    @Published var loading = false
    @Published var applying = false
    @Published var error: String?
    private var maximum = 100
    private var revision = 0
    private var pending: Task<Void, Never>?
    /// A slider change made while the monitor is still being read; applied once it is ready.
    private var queued: Double?
    var selected: Monitor? { monitors.first { $0.id == selectedID } }
    /// The selected monitor's name, or the last one seen while monitors are being scanned.
    var displayName: String {
        selected?.name ?? UserDefaults.standard.string(forKey: "displayName") ?? "External Display"
    }

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
        queued = nil
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
        hasValue = true
        ready = true
        loading = false
        UserDefaults.standard.set(monitor.id, forKey: "display")
        UserDefaults.standard.set(monitor.name, forKey: "displayName")
        UserDefaults.standard.set(brightness, forKey: "lastBrightness")
        if let queued {
            self.queued = nil
            setBrightness(queued)
        }
    }

    func setBrightness(_ percent: Double) {
        if loading && hasValue {
            queued = min(100, max(0, percent))
            brightness = queued!
            return
        }
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
                UserDefaults.standard.set(brightness, forKey: "lastBrightness")
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

enum Motion {
    /// Fitted to a frame-by-frame recording of Control Center on macOS 27: its panel forms
    /// on a critically damped spring and drifts 3 pt — down while appearing (ω ≈ 23 rad/s,
    /// half formed after ~70 ms) and up while disappearing (ω ≈ 31 rad/s).
    static let openResponse = 2 * Double.pi / 23
    /// Slower than the fitted 31 rad/s because dematerializing finishes ahead of the spring.
    static let closeResponse = 2 * Double.pi / 21
    static let drift: CGFloat = 3
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var open: Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: openResponse, dampingFraction: 1) }
    static var close: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: closeResponse, dampingFraction: 1) }
    static let value = Animation.spring(response: 0.3, dampingFraction: 1)
}

enum PanelMetrics {
    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 24
    /// Transparent room around the card for the glass edge and shadow. Clicks there pass
    /// through to whatever is underneath because those pixels are fully transparent.
    static let margin = NSEdgeInsets(top: 4, left: 24, bottom: 32, right: 24)
}

@MainActor
final class PanelPresentation: ObservableObject {
    @Published var visible = false
}

/// The card's surface: Liquid Glass that materializes on macOS 26+, a plain material before.
struct PanelSurface: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                if visible {
                    content
                        .glassEffect(.regular, in: .rect(cornerRadius: PanelMetrics.cornerRadius))
                        .glassEffectTransition(.materialize)
                }
            }
        } else if visible {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
                .transition(.opacity)
        }
    }
}

struct PanelCard: View {
    @ObservedObject var model: BrightnessModel
    @ObservedObject var login: LoginSettings
    var live: Bool { model.ready || (model.loading && model.hasValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(live ? "\(Int(model.brightness.rounded()))%" : "—")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: model.brightness))
                optionsMenu
            }
            .padding(.leading, 5)
            .padding(.trailing, -2)

            HStack(spacing: 6) {
                Image(systemName: "sun.min.fill").font(.system(size: 11, weight: .medium)).frame(width: 18)
                Slider(value: Binding(get: { model.brightness },
                                      set: { model.setBrightness($0.rounded()) }),
                       in: 0...100)
                    .controlSize(.regular)
                    .tint(Color(nsColor: NSColor(name: nil) { appearance in
                        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : NSColor(white: 0.25, alpha: 1)
                    }))
                    .disabled(!live)
                    .focusable(false)
                    .accessibilityLabel("Monitor brightness")
                Image(systemName: "sun.max.fill").font(.system(size: 15, weight: .medium)).frame(width: 18)
            }
            .padding(.horizontal, 2)
            .animation(Motion.value, value: model.brightness)

            if let message = model.error ?? login.error {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
            }
            if login.needsApproval {
                Button("Allow in Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.horizontal, 5)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 15, bottom: 15, trailing: 15))
        .frame(width: PanelMetrics.width, alignment: .leading)
    }

    private var optionsMenu: some View {
        let busy = model.loading || model.applying
        return Menu {
            if model.monitors.count > 1 {
                Picker("Monitor", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.monitors) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(busy)
                Divider()
            }
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r")
                .disabled(busy)
            Toggle("Launch at Login", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
            Divider()
            Button("Quit Monitor Brightness") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
        .accessibilityLabel("Options")
    }
}

struct PanelRoot: View {
    @ObservedObject var presentation: PanelPresentation
    let model: BrightnessModel
    let login: LoginSettings

    var body: some View {
        let m = PanelMetrics.margin
        // The hidden copy keeps the window's size stable while the visible card forms.
        PanelCard(model: model, login: login)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .top) {
                PanelCard(model: model, login: login)
                    .modifier(PanelSurface(visible: presentation.visible))
                    .offset(y: presentation.visible || Motion.reduced ? 0 : -Motion.drift)
            }
            .padding(EdgeInsets(top: m.top, leading: m.left, bottom: m.bottom, trailing: m.right))
    }
}

// Keep the panel inside its screen and below the menu bar, including screens
// whose coordinate origin is above or below the primary display.
func panelFrame(size: NSSize, anchor: NSRect, visible: NSRect, screen: NSRect, menuBarHeight: CGFloat) -> NSRect {
    let top = min(visible.maxY, screen.maxY - menuBarHeight) - 4
    let x = max(visible.minX + 8, min(anchor.midX - size.width / 2, visible.maxX - size.width - 8))
    return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
}

/// The window around a card frame, including the transparent margin.
func windowFrame(card: NSRect) -> NSRect {
    let m = PanelMetrics.margin
    return NSRect(x: card.minX - m.left, y: card.minY - m.bottom,
                  width: card.width + m.left + m.right, height: card.height + m.top + m.bottom)
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = BrightnessModel()
    let login = LoginSettings()
    var statusItem: NSStatusItem!
    private var panel: BrightnessPanel?
    private var presentation: PanelPresentation?
    private var hosting: NSHostingView<PanelRoot>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var opening = false
    private var closing = false
    private var menuIsOpen = false
    private var sizeObserver: AnyCancellable?
    private var scrollRemainder = 0.0
    private var closeGeneration = 0
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
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(hidePanel), name: NSApplication.didResignActiveNotification, object: nil)
        // The ⋯ menu runs its own event loop; clicks in it must not dismiss the panel.
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuIsOpen = true }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuIsOpen = false }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
        login.configureOnFirstLaunch()
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.togglePanel() }
        }
    }

    @objc func displaysChanged() {
        // Read hardware only while controls are visible. Opening always rescans.
        if panel?.isVisible == true {
            model.refresh()
            positionPanel()
        }
    }

    private func createPanel() -> BrightnessPanel {
        let presentation = PanelPresentation()
        let content = NSHostingView(rootView: PanelRoot(presentation: presentation, model: model, login: login))
        content.sizingOptions = [.intrinsicContentSize]
        // Non-activating, like Control Center: the panel takes keyboard focus without
        // activating the app, so the front app's windows and menu bar stay as they are.
        let window = BrightnessPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        window.delegate = self
        window.title = "Monitor Brightness"
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false // the glass draws its own edge; a window shadow can't follow it forming
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = content
        window.onEscape = { [weak self] in self?.hidePanel() }
        self.presentation = presentation
        hosting = content
        // Error and setup lines change the card's height; follow it.
        sizeObserver = model.objectWillChange.merge(with: login.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.positionPanel() }
        return window
    }

    private func targetFrame() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main,
              let hosting else { return nil }
        hosting.layoutSubtreeIfNeeded()
        let m = PanelMetrics.margin
        let size = hosting.fittingSize
        let card = NSSize(width: size.width - m.left - m.right, height: size.height - m.top - m.bottom)
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return windowFrame(card: panelFrame(size: card, anchor: anchor, visible: screen.visibleFrame,
                                            screen: screen.frame, menuBarHeight: NSStatusBar.system.thickness))
    }

    private func positionPanel() {
        guard !closing, let panel, let frame = targetFrame(), frame != panel.frame else { return }
        // The card is pinned to the top of the window, so resizing never moves it.
        panel.setFrame(frame, display: true)
    }

    private func adjust(by delta: Double) {
        guard model.ready || (model.loading && model.hasValue) else { return }
        model.setBrightness(min(100, max(0, (model.brightness + delta).rounded())))
    }

    private func watchForDismissal() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            // The menu bar delivers the status item's own click here too; togglePanel handles it.
            if let frame = self.statusItem.button?.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
            self.trace("click outside")
            self.hidePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible, !self.menuIsOpen else { return event }
            switch event.type {
            case .keyDown:
                let step = event.modifierFlags.contains(.option) ? 1.0 : 5.0
                switch event.keyCode {
                case 53: self.hidePanel(); return nil
                case 123, 125: self.adjust(by: -step); return nil
                case 124, 126: self.adjust(by: step); return nil
                default: return event
                }
            case .scrollWheel where event.window === panel:
                // Physical "up" brightens regardless of the natural scrolling setting.
                let delta = Double(event.scrollingDeltaY) * (event.isDirectionInvertedFromDevice ? -1 : 1)
                self.scrollRemainder += delta * (event.hasPreciseScrollingDeltas ? 0.25 : 2)
                let steps = self.scrollRemainder.rounded(.towardZero)
                if steps != 0 {
                    self.scrollRemainder -= steps
                    self.adjust(by: steps)
                }
                return nil
            case .leftMouseDown, .rightMouseDown:
                if event.window !== panel && event.window !== self.statusItem.button?.window {
                    self.hidePanel()
                }
                return event
            default:
                return event
            }
        }
    }

    @objc func hidePanel() {
        guard let panel, !closing else { return }
        trace("dismiss requested")
        closing = true
        statusItem.button?.highlight(false)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        panel.ignoresMouseEvents = true
        closeGeneration += 1
        let generation = closeGeneration
        withAnimation(Motion.close, completionCriteria: .logicallyComplete) {
            presentation?.visible = false
        } completion: { [weak self, weak panel] in
            // Skip if the panel was reopened mid-close, or closed again since.
            guard let self, self.closing, self.closeGeneration == generation else { return }
            panel?.orderOut(nil)
            panel?.contentView = nil
            panel?.close()
            self.panel = nil
            self.presentation = nil
            self.hosting = nil
            self.sizeObserver = nil
            self.opening = false
            self.closing = false
            self.trace("dismissed panelReleased=\(self.panel == nil)")
        }
    }

    @objc func togglePanel() {
        if closing { reopen(); return }
        if panel != nil { hidePanel(); return }
        model.refresh()
        login.refresh()
        let window = createPanel()
        panel = window
        guard let frame = targetFrame() else { panel = nil; return }
        window.setFrame(frame, display: false)
        opening = true
        statusItem.button?.highlight(true)
        window.makeKeyAndOrderFront(nil)
        watchForDismissal()
        // Let the empty window reach the screen first so the card visibly forms on it.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.panel === window, !self.closing else { return }
            withAnimation(Motion.open) {
                self.presentation?.visible = true
            } completion: { [weak self] in
                self?.opening = false
                self?.trace("opened keyWindow=\(window.isKeyWindow) frame=\(NSStringFromRect(window.frame))")
            }
        }
    }

    /// Clicking the icon while the panel dissolves forms it again from where it is.
    private func reopen() {
        guard let panel else { return }
        trace("reopen during close")
        closing = false
        opening = true
        panel.ignoresMouseEvents = false
        statusItem.button?.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        watchForDismissal()
        withAnimation(Motion.open) {
            presentation?.visible = true
        } completion: { [weak self] in
            self?.opening = false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Another app or window took focus (Command-Tab, Mission Control, …).
        guard (notification.object as? NSWindow) === panel, !opening, !menuIsOpen else { return }
        trace("resigned key")
        hidePanel()
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
    let card = NSRect(x: 100, y: 500, width: 300, height: 75)
    let window = windowFrame(card: card)
    precondition(window.maxY == card.maxY + PanelMetrics.margin.top && window.minX == card.minX - PanelMetrics.margin.left)
    print("Window margin surrounds the card without moving it")
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
