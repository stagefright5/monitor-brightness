import AppKit
import Darwin
import ServiceManagement
import Combine
import QuartzCore
import SwiftUI

struct Monitor: Identifiable, Equatable {
    let id: String
    let name: String
    /// Dimmed by scaling the display's gamma, for monitors that don't answer DDC/CI.
    var software = false
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

/// Software brightness for monitors without DDC/CI (many portable and TV-style displays):
/// scales the display's gamma table, as MonitorControl and Lunar do. macOS restores the
/// normal table when the app quits, so the saved level is reapplied on launch, and again
/// whenever the system resets the table (display changes, wake, colour profile changes).
@MainActor
enum SoftwareDimmer {
    /// The darkest the slider goes, as a fraction of normal output, so 0% never blacks out.
    static let floor = 0.1
    private static let levelsKey = "softwareBrightness"

    private struct Table: Equatable {
        var red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]
        func scaled(_ factor: Double) -> Table {
            let f = CGGammaValue(factor)
            return Table(red: red.map { $0 * f }, green: green.map { $0 * f }, blue: blue.map { $0 * f })
        }
        func matches(_ other: Table) -> Bool {
            guard red.count == other.red.count else { return false }
            return zip(red + green + blue, other.red + other.green + other.blue).allSatisfy { abs($0 - $1) < 0.002 }
        }
    }
    /// Each display's table before dimming, and what was last written to it.
    private static var baselines: [String: Table] = [:]
    private static var applied: [String: Table] = [:]

    static func factor(for percent: Double) -> Double {
        floor + (1 - floor) * min(100, max(0, percent)) / 100
    }

    static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// External monitors, excluding the built-in screen and this app's HiDPI display.
    static func externalMonitors() -> [Monitor] {
        onlineDisplays()
            .filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != HiDPIController.vendorID }
            .compactMap { id in
                guard let uuid = uuid(of: id) else { return nil }
                let name = NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "External Display"
                return Monitor(id: uuid, name: name, software: true)
            }
    }

    private static func display(for uuid: String) -> CGDirectDisplayID? {
        onlineDisplays().first { Self.uuid(of: $0) == uuid }
    }

    private static var levels: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: levelsKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: levelsKey) }
    }

    static func level(for uuid: String) -> Double { levels[uuid] ?? 100 }

    @discardableResult
    static func setLevel(_ percent: Double, for uuid: String) -> Bool {
        levels[uuid] = min(100, max(0, percent))
        return apply(uuid, force: true)
    }

    private static func read(_ display: CGDirectDisplayID) -> Table? {
        let capacity = 256
        var red = [CGGammaValue](repeating: 0, count: capacity), green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, UInt32(capacity), &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let n = Int(count)
        return Table(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    /// Writes the saved level to a display. Without `force`, only rewrites a table that
    /// something else replaced, so it's cheap to call repeatedly.
    @discardableResult
    private static func apply(_ uuid: String, force: Bool) -> Bool {
        guard let display = display(for: uuid), let current = read(display) else { return false }
        // A table that isn't the one we wrote is the system's (or another app's) new normal.
        if baselines[uuid] == nil || !(applied[uuid].map { current.matches($0) } ?? false) {
            baselines[uuid] = current
        } else if !force {
            return true
        }
        let table = baselines[uuid]!.scaled(factor(for: level(for: uuid)))
        guard CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue) == .success
        else { return false }
        applied[uuid] = read(display) ?? table
        return true
    }

    /// Reapplies dimming to connected monitors whose saved level is below 100%.
    static func reapplyAll() {
        let online = Set(externalMonitors().map(\.id))
        for (uuid, level) in levels where level < 100 && online.contains(uuid) {
            apply(uuid, force: false)
        }
    }

    static var anyDimmed: Bool { levels.values.contains { $0 < 100 } }

    static func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
        baselines = [:]
        applied = [:]
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
                let all = DDC.parseDisplays((try? await DDC.run(["display", "list"])) ?? "")
                // Prefer hardware brightness for displays that answer DDC/CI reads.
                var supported: [Monitor] = []
                for monitor in all {
                    if let _ = try? await DDC.read(monitor) { supported.append(monitor) }
                }
                // Every other external monitor gets software dimming.
                for monitor in SoftwareDimmer.externalMonitors() where !supported.contains(where: { $0.id == monitor.id }) {
                    supported.append(monitor)
                }
                guard revision == currentRevision else { return }
                monitors = supported
                guard !supported.isEmpty else {
                    throw BrightnessError(message: "No external monitor found. Check the cable, then try Refresh.")
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
        if monitor.software {
            maximum = 100
            brightness = SoftwareDimmer.level(for: monitor.id)
        } else {
            let maxValue = try await DDC.read(monitor, maximum: true)
            let value = try await DDC.read(monitor)
            guard revision == currentRevision else { return }
            guard value <= maxValue else { throw BrightnessError(message: "The monitor reported an invalid brightness range.") }
            maximum = maxValue
            brightness = Double(value) / Double(maxValue) * 100
        }
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
        if monitor.software {
            // Gamma changes are instant, so follow the slider without debouncing.
            applying = false
            UserDefaults.standard.set(brightness, forKey: "lastBrightness")
            error = SoftwareDimmer.setLevel(brightness, for: monitor.id)
                ? nil : "Couldn’t dim this monitor. Try Refresh."
            return
        }
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

/// macOS font smoothing ("AppleFontSmoothing" in the current host's global domain).
/// Smoothing thickens glyph stems; it suits Retina screens but softens text at ~90 PPI.
@MainActor
final class TextSmoothing: ObservableObject {
    private static let key = "AppleFontSmoothing" as CFString
    /// What running apps, including this one, were launched with.
    let sharperAtLaunch: Bool
    @Published private(set) var sharper: Bool

    init() {
        let current = Self.read() == 0
        sharper = current
        sharperAtLaunch = current
    }

    static func read() -> Int? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesCurrentHost) as? Int
    }

    func setSharper(_ value: Bool) {
        CFPreferencesSetValue(Self.key, (value ? 0 : 1) as CFNumber, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        sharper = Self.read() == 0
    }
}

/// Sample text drawn with or without font smoothing, so the setting can be compared
/// immediately. Smoothing only applies on an opaque background, hence the filled well.
final class SmoothingSampleView: NSView {
    var smooth = true { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(smooth)
        let text = "The quick brown fox jumps over the lazy dog" as NSString
        let font = NSFont.systemFont(ofSize: 12)
        let y = ((bounds.height - font.ascender + font.descender) / 2).rounded()
        text.draw(at: NSPoint(x: 8, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}

struct SmoothingSample: NSViewRepresentable {
    let smooth: Bool
    func makeNSView(context: Context) -> SmoothingSampleView {
        let view = SmoothingSampleView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 7
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.smooth = smooth
        return view
    }
    func updateNSView(_ view: SmoothingSampleView, context: Context) { view.smooth = smooth }
}

/// HiDPI for a low-density external monitor: macOS draws onto a virtual HiDPI display at
/// twice the monitor's resolution, and the monitor mirrors it, scaled down. The virtual
/// display lives only as long as this app, so quitting or crashing restores the normal
/// setup on its own. Uses CoreGraphics' private CGVirtualDisplay, as display utilities do.
/// HiDPI on a Mac is always 2×, so drawing more pixels means a larger desktop: each level
/// widens what the monitor "looks like" and doubles that for drawing.
struct HiDPILevel {
    let label: String
    let factor: Double
    static let all = [HiDPILevel(label: "4K", factor: 1), HiDPILevel(label: "4.5K", factor: 7.0 / 6.0),
                      HiDPILevel(label: "5K", factor: 4.0 / 3.0)]
}

/// The desktop size, in points, for a monitor's native pixels at a level (kept even).
func hiDPILooksLike(nativeWidth: Int, nativeHeight: Int, factor: Double) -> (width: Int, height: Int) {
    func even(_ value: Double) -> Int { Int((value / 2).rounded()) * 2 }
    return (even(Double(nativeWidth) * factor), even(Double(nativeHeight) * factor))
}

@MainActor
final class HiDPIController: ObservableObject {
    static let vendorID: UInt32 = 0xF0F0
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "hiDPI")
    @Published private(set) var level = min(max(UserDefaults.standard.integer(forKey: "hiDPILevel"), 0), HiDPILevel.all.count - 1)
    /// What the active virtual display looks like and draws at, for the panel.
    @Published private(set) var summary: String?
    @Published private(set) var error: String?
    /// When the user last switched HiDPI or its size; the display rebuild that follows
    /// briefly takes focus from the panel, which shouldn't close it.
    private(set) var changedAt: Date?
    var isReconfiguring: Bool { changedAt.map { Date().timeIntervalSince($0) < 3 } ?? false }
    private var display: CGVirtualDisplay?
    private var target: CGDirectDisplayID?
    /// True while the new virtual display is registering; display-change callbacks wait.
    private var starting = false

    func start() { if enabled { apply() } }

    func setEnabled(_ value: Bool) {
        enabled = value
        changedAt = Date()
        UserDefaults.standard.set(value, forKey: "hiDPI")
        error = nil
        value ? apply() : tearDown()
    }

    func setLevel(_ value: Int) {
        guard value != level, HiDPILevel.all.indices.contains(value) else { return }
        level = value
        changedAt = Date()
        UserDefaults.standard.set(value, forKey: "hiDPILevel")
        guard enabled else { return }
        tearDown()
        apply()
    }

    /// The external monitor to enhance: not built in, not our own virtual display.
    static func externalDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let external = ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != vendorID
        }
        return external.first { CGDisplayIsMain($0) != 0 || CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
            ?? external.first
    }

    private func apply() {
        guard let physical = Self.externalDisplay() else {
            tearDown()
            error = "Connect an external monitor to use HiDPI."
            return
        }
        if starting { return }
        if let display, target == physical {
            // Already set up; only restore the mirror if the system dropped it.
            if CGDisplayMirrorsDisplay(physical) != display.displayID { mirror(physical, to: display.displayID) }
            return
        }
        tearDown()
        // Size the virtual display from the monitor's native mode, at twice the pixels.
        let native = (CGDisplayCopyAllDisplayModes(physical, nil) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() }
            .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            ?? CGDisplayCopyDisplayMode(physical)
        guard let native else { error = "Couldn’t read this monitor’s resolution."; return }
        let size = hiDPILooksLike(nativeWidth: native.pixelWidth, nativeHeight: native.pixelHeight,
                                  factor: HiDPILevel.all[level].factor)
        let width = UInt32(size.width), height = UInt32(size.height)
        let refresh = native.refreshRate > 0 ? native.refreshRate : 60

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "HiDPI " + (NSScreen.screens.first { $0.displayID == physical }?.localizedName ?? "Display")
        descriptor.maxPixelsWide = width * 2
        descriptor.maxPixelsHigh = height * 2
        descriptor.sizeInMillimeters = CGDisplayScreenSize(physical)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = CGDisplayModelNumber(physical)
        descriptor.serialNum = CGDisplaySerialNumber(physical)
        descriptor.terminationHandler = { _, _ in }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            error = "macOS didn’t allow a HiDPI display."
            return
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        guard let mode = CGVirtualDisplayMode(width: width, height: height, refreshRate: refresh) else { return }
        settings.modes = [mode]
        guard display.apply(settings) else {
            error = "macOS didn’t allow a HiDPI display."
            return
        }
        self.display = display
        target = physical
        summary = "Looks like \(width)×\(height) · draws at \(width * 2)×\(height * 2)"
        starting = true
        waitThenMirror(physical, to: display.displayID, attempts: 30)
    }

    /// The window server registers a new display asynchronously.
    private func waitThenMirror(_ physical: CGDirectDisplayID, to virtual: CGDirectDisplayID, attempts: Int) {
        guard display?.displayID == virtual else { starting = false; return }
        if CGDisplayCopyDisplayMode(virtual) != nil {
            starting = false
            mirror(physical, to: virtual)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitThenMirror(physical, to: virtual, attempts: attempts - 1)
            }
        } else {
            starting = false
            tearDown()
            error = "The HiDPI display didn’t start. Try again."
        }
    }

    private func mirror(_ physical: CGDirectDisplayID, to virtual: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(config, physical, virtual)
        if CGCompleteDisplayConfiguration(config, .forSession) != .success {
            CGCancelDisplayConfiguration(config)
            error = "Couldn’t mirror the monitor to the HiDPI display."
        }
    }

    private func tearDown() {
        if let target, let display, CGDisplayMirrorsDisplay(target) == display.displayID {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success {
                CGConfigureDisplayMirrorOfDisplay(config, target, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(config, .forSession)
            }
        }
        // Releasing the virtual display removes it; macOS restores the previous arrangement.
        starting = false
        display = nil
        target = nil
        summary = nil
    }

    /// Called on display changes: follow the monitor, and never leave the virtual display
    /// behind without it (a laptop screen would otherwise mirror a blurry HiDPI copy).
    func displaysChanged() {
        guard enabled else { return }
        if Self.externalDisplay() == nil {
            tearDown()
        } else {
            apply()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
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
    @ObservedObject var smoothing: TextSmoothing
    @ObservedObject var hiDPI: HiDPIController
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

            if model.selected?.software == true {
                Text("Dimmed in software. This monitor doesn’t support hardware brightness (DDC/CI).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sharper text").font(.system(size: 12))
                    Spacer()
                    Toggle("Sharper text", isOn: Binding(get: { smoothing.sharper },
                                                         set: { smoothing.setSharper($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .padding(.horizontal, 5)
                HStack {
                    Text("HiDPI").font(.system(size: 12))
                    Spacer()
                    Toggle("HiDPI", isOn: Binding(get: { hiDPI.enabled }, set: { hiDPI.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .padding(.horizontal, 5)
                .help("Draw at twice the monitor’s resolution and scale down to fit.")
                if hiDPI.enabled {
                    Picker("HiDPI size", selection: Binding(get: { hiDPI.level }, set: { hiDPI.setLevel($0) })) {
                        ForEach(HiDPILevel.all.indices, id: \.self) { Text(HiDPILevel.all[$0].label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5)
                    if let summary = hiDPI.summary {
                        Text(summary)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                    }
                }
                if let error = hiDPI.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                }
                SmoothingSample(smooth: !smoothing.sharper)
                    .frame(height: 26)
                    .accessibilityHidden(true)
                if smoothing.sharper != smoothing.sharperAtLaunch {
                    Text("Other apps update when reopened.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                }
            }
            .padding(.top, 2)

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
    let smoothing: TextSmoothing
    let hiDPI: HiDPIController

    var body: some View {
        let m = PanelMetrics.margin
        // The hidden copy keeps the window's size stable while the visible card forms.
        PanelCard(model: model, login: login, smoothing: smoothing, hiDPI: hiDPI)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .top) {
                PanelCard(model: model, login: login, smoothing: smoothing, hiDPI: hiDPI)
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
    let smoothing = TextSmoothing()
    let hiDPI = HiDPIController()
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
    private var dimmingTimer: Timer?
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
        hiDPI.start()
        // Software dimming doesn't outlive the app; restore the saved level, and put it back
        // if macOS resets the gamma table (wake, unlock, colour profile changes).
        SoftwareDimmer.reapplyAll()
        dimmingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { if SoftwareDimmer.anyDimmed { SoftwareDimmer.reapplyAll() } }
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.togglePanel() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SoftwareDimmer.restoreAll()
    }

    @objc func displaysChanged() {
        hiDPI.displaysChanged()
        SoftwareDimmer.reapplyAll()
        // Read hardware only while controls are visible. Opening always rescans.
        if panel?.isVisible == true {
            model.refresh()
            positionPanel()
            if hiDPI.isReconfiguring { panel?.makeKeyAndOrderFront(nil) }
        }
    }

    private func createPanel() -> BrightnessPanel {
        let presentation = PanelPresentation()
        let content = NSHostingView(rootView: PanelRoot(presentation: presentation, model: model, login: login, smoothing: smoothing, hiDPI: hiDPI))
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
        sizeObserver = model.objectWillChange.merge(with: login.objectWillChange, smoothing.objectWillChange, hiDPI.objectWillChange)
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
                    self.trace("mouse down in other window: \(String(describing: event.window)) level=\(event.window?.level.rawValue ?? -1) parent=\(String(describing: event.window?.parent))")
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
        if hiDPI.isReconfiguring {
            // Displays are being rebuilt; take focus back once they settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let panel = self.panel, !self.closing else { return }
                self.positionPanel()
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        trace("resigned key; app active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow)) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") event=\(String(describing: NSApp.currentEvent?.type)) window=\(String(describing: NSApp.currentEvent?.window))")
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
    let displays = DDC.parseDisplays((try? DDC.runSync(["display", "list"])) ?? "")
    var hardware = Set<String>()
    for display in displays {
        if let value = try? DDC.runSync(["display", display.id, "get", "luminance"]) {
            hardware.insert(display.id)
            print("\(display.name): \(value) (DDC/CI)")
        }
    }
    MainActor.assumeIsolated {
        for monitor in SoftwareDimmer.externalMonitors() where !hardware.contains(monitor.id) {
            print("\(monitor.name): \(Int(SoftwareDimmer.level(for: monitor.id)))% (software dimming)")
        }
    }
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
    precondition(hiDPILooksLike(nativeWidth: 1920, nativeHeight: 1080, factor: HiDPILevel.all[0].factor) == (1920, 1080))
    precondition(hiDPILooksLike(nativeWidth: 1920, nativeHeight: 1080, factor: HiDPILevel.all[1].factor) == (2240, 1260))
    precondition(hiDPILooksLike(nativeWidth: 1920, nativeHeight: 1080, factor: HiDPILevel.all[2].factor) == (2560, 1440))
    print("HiDPI levels draw at 3840×2160, 4480×2520 and 5120×2880 on a 1080p monitor")
    MainActor.assumeIsolated {
        precondition(SoftwareDimmer.factor(for: 100) == 1)
        precondition(abs(SoftwareDimmer.factor(for: 0) - SoftwareDimmer.floor) < 1e-9)
        precondition(SoftwareDimmer.factor(for: -5) == SoftwareDimmer.factor(for: 0))
        precondition(SoftwareDimmer.factor(for: 50) > SoftwareDimmer.factor(for: 40))
    }
    print("Software dimming never goes fully dark")
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
