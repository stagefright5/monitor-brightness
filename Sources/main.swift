import AppKit
import SwiftUI
import Darwin

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

struct BrightnessView: View {
    @ObservedObject var model: BrightnessModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "display").font(.system(size: 27)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monitor Brightness").font(.headline)
                    Text(model.selected?.name ?? "External display").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh connected monitors")
                    .accessibilityLabel("Refresh monitors").disabled(model.loading || model.applying)
            }
            if model.monitors.count > 1 {
                Picker("Monitor", selection: Binding(get: { model.selectedID }, set: model.select)) {
                    ForEach(model.monitors) { Text($0.name).tag($0.id) }
                }.disabled(model.loading || model.applying)
            }
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(model.ready ? "\(Int(model.brightness.rounded()))" : "—")
                        .font(.system(size: 60, weight: .light, design: .rounded)).monospacedDigit()
                    Text("%").font(.title2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { model.brightness }, set: model.setBrightness), in: 0...100, step: 1)
                        .accessibilityLabel("Monitor brightness")
                        .accessibilityValue("\(Int(model.brightness)) percent")
                    Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach([25, 50, 75, 100], id: \.self) { value in
                        Button("\(value)%") { model.setBrightness(Double(value)) }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                            .accessibilityLabel("Set brightness to \(value) percent")
                    }
                }
            }.disabled(!model.ready)
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(model.loading ? "Connecting to monitor…" : model.applying ? "Adjusting brightness…" : "Hardware brightness · Connected",
                          systemImage: model.loading || model.applying ? "circle.dotted" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Also available in your menu bar").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(24).frame(width: 370)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BrightnessModel()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = BrightnessView(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 330),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Monitor Brightness"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Monitor Brightness")
        statusItem.button?.toolTip = "Monitor Brightness"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func displaysChanged() { model.refresh() }
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        model.refresh()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if CommandLine.arguments.contains("--check") {
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
    print("All checks passed")
} else {
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
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
