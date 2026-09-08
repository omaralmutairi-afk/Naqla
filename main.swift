import Cocoa
import QuartzCore
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

extension Notification.Name {
    static let naqlaSettingsChanged = Notification.Name("naqlaSettingsChanged")
    static let naqlaOpenSettingsRequested = Notification.Name("naqlaOpenSettingsRequested")
}

/// Wraps SMAppService so "launch at login" is a real, system-visible login
/// item (shows up in System Settings ▸ General ▸ Login Items) instead of a
/// LaunchAgent plist living outside the app bundle where nothing but we know
/// about it.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Naqla] LoginItem toggle failed: \(error)")
            fflush(stdout)
        }
    }
}

/// Every user-facing preference, backed by UserDefaults. Reading is cheap and
/// direct (no caching) since these are only touched on click/expand/redraw,
/// never in a hot loop. Any write posts `.naqlaSettingsChanged` so the wheel,
/// the hotkey, and the tracker can pick it up immediately.
final class SettingsStore {
    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    private enum Key {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let maxApps = "maxApps"
        static let iconScale = "iconScale"
        static let accentColor = "accentColorHex"
        static let wheelOpacity = "wheelOpacity"
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .naqlaSettingsChanged, object: nil)
    }

    var hotKeyCode: UInt32 {
        get {
            let v = d.object(forKey: Key.hotKeyCode) as? Int
            return v.map(UInt32.init) ?? UInt32(kVK_ANSI_R)
        }
        set { d.set(Int(newValue), forKey: Key.hotKeyCode); notifyChanged() }
    }

    var hotKeyModifiers: UInt32 {
        get {
            let v = d.object(forKey: Key.hotKeyModifiers) as? Int
            return v.map(UInt32.init) ?? UInt32(cmdKey | shiftKey)
        }
        set { d.set(Int(newValue), forKey: Key.hotKeyModifiers); notifyChanged() }
    }

    var maxApps: Int {
        get {
            let v = d.object(forKey: Key.maxApps) as? Int ?? 10
            return min(14, max(4, v))
        }
        set { d.set(newValue, forKey: Key.maxApps); notifyChanged() }
    }

    /// Multiplies the base icon size and arc radius; 1.0 matches the original design.
    var iconScale: Double {
        get {
            let v = d.object(forKey: Key.iconScale) as? Double ?? 1.0
            return min(1.3, max(0.7, v))
        }
        set { d.set(newValue, forKey: Key.iconScale); notifyChanged() }
    }

    /// Tints the core's ring and each app icon's border. Defaults to the mint
    /// tile color already in the brand artwork, so first launch looks unchanged.
    var accentColor: NSColor {
        get {
            guard let hex = d.string(forKey: Key.accentColor), let color = NSColor(hex: hex) else {
                return NSColor(srgbRed: 0.365, green: 0.804, blue: 0.643, alpha: 1)
            }
            return color
        }
        set { d.set(newValue.hexString, forKey: Key.accentColor); notifyChanged() }
    }

    var wheelOpacity: Double {
        get {
            let v = d.object(forKey: Key.wheelOpacity) as? Double ?? 1.0
            return min(1.0, max(0.5, v))
        }
        set { d.set(newValue, forKey: Key.wheelOpacity); notifyChanged() }
    }

    var launchAtLogin: Bool {
        get { LoginItem.isEnabled }
        set { LoginItem.setEnabled(newValue); notifyChanged() }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#5DCDA4" }
        // Wide-gamut picks convert to components outside 0…1, which without
        // clamping format to three characters and make the whole string
        // unparseable on the way back in — the accent would silently reset.
        func channel(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(c.redComponent), channel(c.greenComponent), channel(c.blueComponent))
    }
}

/// Thin wrapper over the Accessibility API. Used only to answer what
/// NSRunningApplication can't: whether an active app's window is actually on
/// screen, or just minimized into the Dock while the app stays "active".
enum AXInspector {
    private static func windows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// `true` when we can't inspect the app's windows at all — better to fall
    /// back to the old activate/hide behavior than to assume it's minimized.
    static func hasVisibleWindow(pid: pid_t) -> Bool {
        let wins = windows(for: pid)
        guard !wins.isEmpty else { return true }
        return wins.contains { !isMinimized($0) }
    }

    static func restoreMinimizedWindows(pid: pid_t) {
        for window in windows(for: pid) where isMinimized(window) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }
}

final class RecentAppsTracker {
    static let shared = RecentAppsTracker()
    private var apps: [NSRunningApplication] = []

    /// Quit apps lose their icon, so they must never reach the wheel.
    /// Trimmed to the current setting here too, in case the max was lowered
    /// after apps already accumulated past the new limit.
    var recentApps: [NSRunningApplication] {
        Array(apps.filter { !$0.isTerminated }.prefix(SettingsStore.shared.maxApps))
    }

    func start() {
        seedFromRunningApps()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    /// The tracker otherwise only learns of an app when it activates, so right
    /// after login the wheel would come up empty until the user happened to
    /// switch apps. Launch order carries no recency, so this just makes sure
    /// whatever is frontmost leads.
    private func seedFromRunningApps() {
        let mine = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != mine && !$0.isTerminated
        }.sorted { lhs, rhs in lhs.isActive && !rhs.isActive }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular
        else { return }
        apps.removeAll { $0.processIdentifier == app.processIdentifier }
        apps.insert(app, at: 0)
        let cap = SettingsStore.shared.maxApps
        if apps.count > cap { apps.removeLast(apps.count - cap) }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        apps.removeAll { $0.processIdentifier == app.processIdentifier || $0.isTerminated }
    }
}

/// A single app icon on the arc. Handles its own hover pop + click.
final class AppIconView: NSView {
    let app: NSRunningApplication
    var targetOrigin: NSPoint = .zero
    var onForceQuit: ((AppIconView) -> Void)?

    private let imageLayer = CALayer()
    private let closeBadge = CALayer()
    private let closeGlyph = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private let hoverScale: CGFloat = 1.22

    init(app: NSRunningApplication, size: CGFloat) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        toolTip = app.localizedName

        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 4

        imageLayer.frame = bounds
        imageLayer.cornerRadius = size / 2
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.contents = app.icon
        imageLayer.borderWidth = 1.5
        imageLayer.borderColor = SettingsStore.shared.accentColor.cgColor
        layer?.addSublayer(imageLayer)

        buildCloseBadge()
    }

    // The badge sits in the square's top-right corner, which the circular
    // icon leaves empty — so it covers almost none of the artwork. The upper
    // bound is what keeps it off the icon's centre: a flat 15pt minimum meant
    // that once icons shrank past 30pt (seven apps or more) the badge reached
    // the middle, and an ordinary click on an app force-quit it instead.
    private var badgeSize: CGFloat { min(bounds.width * 0.46, max(13, bounds.width * 0.40)) }

    /// Under ~22pt there is no size that is both clear of the centre and big
    /// enough to aim at, so those icons get no badge at all rather than a
    /// 7pt one. Shrinking the icons further is the user's own choice, and
    /// losing force-quit there beats killing an app by mis-clicking.
    private var showsBadge: Bool { badgeSize >= 10 }

    private var badgeFrame: NSRect {
        let s = badgeSize
        return NSRect(x: bounds.maxX - s, y: bounds.maxY - s, width: s, height: s)
    }

    private func buildCloseBadge() {
        let s = badgeSize
        closeBadge.frame = badgeFrame
        closeBadge.cornerRadius = s / 2
        closeBadge.backgroundColor = NSColor.systemRed.cgColor
        closeBadge.borderWidth = 1
        closeBadge.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        closeBadge.isHidden = true

        let inset = s * 0.32
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: s - inset, y: s - inset))
        path.move(to: CGPoint(x: s - inset, y: inset))
        path.addLine(to: CGPoint(x: inset, y: s - inset))

        closeGlyph.frame = CGRect(origin: .zero, size: CGSize(width: s, height: s))
        closeGlyph.path = path
        closeGlyph.strokeColor = NSColor.white.cgColor
        closeGlyph.fillColor = nil
        closeGlyph.lineWidth = max(1.5, s * 0.13)
        closeGlyph.lineCap = .round
        closeBadge.addSublayer(closeGlyph)

        layer?.addSublayer(closeBadge)
    }

    private func setBadgeVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        closeBadge.isHidden = !visible
        CATransaction.commit()
    }

    /// The hover scale is a layer transform, so AppKit still delivers clicks
    /// in unscaled view coordinates — map the point back before hit-testing
    /// the badge, or the badge's visible position won't match its hit area.
    private func layerSpacePoint(_ point: NSPoint) -> NSPoint {
        guard isHovering else { return point }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        return NSPoint(
            x: c.x + (point.x - c.x) / hoverScale,
            y: c.y + (point.y - c.y) / hoverScale
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        setScale(hoverScale, duration: 0.14)
        setBadgeVisible(showsBadge)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        setScale(1.0, duration: 0.14)
        setBadgeVisible(false)
    }

    // Capturing mouseDown here (even as a no-op) stops it from bubbling up to
    // WheelContainerView, which would otherwise mistake this click for a
    // window drag and swallow the mouseUp meant for activating this app.
    override func mouseDown(with event: NSEvent) {}

    func setScale(_ scale: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction? = nil, animated: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        if let timing { CATransaction.setAnimationTimingFunction(timing) }
        layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        // mouseUp is delivered here even when the release lands far away,
        // so a press the user dragged off and abandoned must do nothing.
        guard bounds.contains(raw) else { return }

        let point = layerSpacePoint(raw)
        if !closeBadge.isHidden && badgeFrame.contains(point) {
            if !app.forceTerminate() {
                app.terminate()
            }
            onForceQuit?(self)
            return
        }

        let isFrontWithVisibleWindow = !app.isHidden
            && app.isActive
            && AXInspector.hasVisibleWindow(pid: app.processIdentifier)

        if isFrontWithVisibleWindow {
            app.hide()
        } else {
            show()
        }
    }

    /// Reproduces a Dock-icon click, then force-restores anything still
    /// minimized via Accessibility — covers apps whose reopen handler doesn't
    /// deminiaturize on its own.
    private func show() {
        app.unhide()
        AXInspector.restoreMinimizedWindows(pid: app.processIdentifier)

        guard let url = app.bundleURL else {
            app.activate(options: [.activateAllWindows])
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

/// The wheel button itself. Purely visual — it passes clicks through to the
/// container so drag and right-click logic stays in one place.
final class CoreView: NSView {
    private let pad: CGFloat
    private static let brandImage: NSImage? = {
        Bundle.main.image(forResource: "CoreIcon")
    }()

    init(coreSize: CGFloat, pad: CGFloat) {
        self.pad = pad
        super.init(frame: NSRect(x: 0, y: 0, width: coreSize + pad * 2, height: coreSize + pad * 2))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: pad, dy: pad)
        let circle = NSBezierPath(ovalIn: rect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        // CoreIcon.png is pre-trimmed to the squircle's own bounding box, so its
        // background already reaches every edge — no separate fill color is
        // needed to hide gaps once the circle clip removes the four corners.
        NSColor(srgbRed: 0.102, green: 0.106, blue: 0.114, alpha: 1).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        Self.brandImage?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        SettingsStore.shared.accentColor.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// A faint arc drawn in the empty ring between the core logo and the fanned
/// satellites. Echoes the arch in Naqla's own logo and closes what would
/// otherwise be dead space between the core and the first row of icons.
final class ArcTrackView: NSView {
    private var path: NSBezierPath?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Rebuilt from the exact same center/radius/angle math buildSatellites
    /// uses for the icons, so the arc always stays concentric with them.
    func update(center: NSPoint, radius: CGFloat, arcStart: Double, arcEnd: Double, xFlip: CGFloat, yFlip: CGFloat) {
        guard radius > 0 else {
            path = nil
            needsDisplay = true
            return
        }
        let steps = 24
        let newPath = NSBezierPath()
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let angleDeg = arcStart + (arcEnd - arcStart) * t
            let rad = angleDeg * .pi / 180
            let point = NSPoint(
                x: center.x + xFlip * radius * CGFloat(cos(rad)),
                y: center.y + yFlip * radius * CGFloat(sin(rad))
            )
            i == 0 ? newPath.move(to: point) : newPath.line(to: point)
        }
        newPath.lineWidth = 1.5
        path = newPath
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let path else { return }
        SettingsStore.shared.accentColor.withAlphaComponent(0.4).setStroke()
        path.stroke()
    }
}

/// Corner wheel: the core sits near the window's top-left, and recent apps
/// fan out along a quarter arc pointing into the screen.
/// The wheel only ever rests in one of the four screen corners — never
/// mid-edge or centered — so both the core's position and the arc's sweep
/// direction are derived from this single piece of state.
enum WheelCorner {
    case topLeft, topRight, bottomLeft, bottomRight

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }

    static func nearest(to point: NSPoint, in screenFrame: NSRect) -> WheelCorner {
        switch (point.x > screenFrame.midX, point.y > screenFrame.midY) {
        case (false, true): return .topLeft
        case (true, true): return .topRight
        case (false, false): return .bottomLeft
        case (true, false): return .bottomRight
        }
    }
}

final class WheelContainerView: NSView {
    static let collapsedSize: CGFloat = 76
    static let expandedSize: CGFloat = 250
    static let coreInset: CGFloat = 38

    private let coreSize: CGFloat = 56
    private let corePad: CGFloat = 6
    private let arcStart: Double = -5
    private let arcEnd: Double = -85

    private lazy var coreView = CoreView(coreSize: coreSize, pad: corePad)
    private lazy var arcTrackView = ArcTrackView(frame: bounds)
    private var satellites: [AppIconView] = []
    private var isExpanded = false
    private var generation = 0
    private var collapseWork: DispatchWorkItem?

    private var dragStartMouse: NSPoint = .zero
    private var isDraggingCore = false
    private var corner: WheelCorner = .topLeft

    private let expandTiming = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    private let collapseTiming = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.9, 0.5)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(coreView)
        addSubview(arcTrackView)
        positionCore()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .naqlaSettingsChanged, object: nil
        )
        applyOpacity()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func settingsChanged() {
        coreView.needsDisplay = true
        applyOpacity()
    }

    private func applyOpacity() {
        window?.alphaValue = CGFloat(SettingsStore.shared.wheelOpacity)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOpacity()
    }

    private var coreCenter: NSPoint {
        NSPoint(
            x: corner.isRight ? bounds.width - Self.coreInset : Self.coreInset,
            y: corner.isBottom ? Self.coreInset : bounds.height - Self.coreInset
        )
    }

    private var coreRect: NSRect {
        coreView.frame.insetBy(dx: corePad, dy: corePad)
    }

    private func positionCore() {
        let center = coreCenter
        coreView.setFrameOrigin(NSPoint(
            x: center.x - coreView.frame.width / 2,
            y: center.y - coreView.frame.height / 2
        ))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionCore()
        arcTrackView.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        collapseWork?.cancel()
        collapseWork = nil
        expand()
    }

    // Debounced: resizing the window and crossing gaps between icons can emit
    // stray exits that would otherwise make the arc flicker.
    override func mouseExited(with event: NSEvent) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
    }

    private static let maxIconDiameter: CGFloat = 48

    private func radius(for count: Int) -> CGFloat {
        let scale = CGFloat(SettingsStore.shared.iconScale)
        let wanted = min(160, 78 + 9 * CGFloat(count - 1)) * scale
        // The window is a fixed 250pt, so past roughly 1.15× the icons at the
        // ends of the arc were being cut off by its edge. Cap the radius using
        // the largest an icon can get, and the whole arc stays inside.
        let room = Self.expandedSize - Self.coreInset - (Self.maxIconDiameter * scale) / 2 - 2
        return min(wanted, room)
    }

    /// Icons shrink as the list grows so the arc keeps them from touching.
    private func iconSize(for count: Int) -> CGFloat {
        let scale = CGFloat(SettingsStore.shared.iconScale)
        guard count > 1 else { return Self.maxIconDiameter * scale }
        let stepDeg = (arcEnd - arcStart) / Double(count - 1)
        let chord = 2 * radius(for: count) * CGFloat(abs(sin(stepDeg / 2 * .pi / 180)))
        let size = min(Self.maxIconDiameter * scale, max(22 * scale, chord * 0.88))
        // radius(for:)'s window-edge cap can shrink the chord well below what
        // the 22pt-scaled floor above assumes is always available — at high
        // icon counts and scales this let the floor push icons past merely
        // touching into real, sometimes severe overlap (confirmed up to
        // ~9pt at scale 1.3 with 14 apps). Never let the floor win over
        // actually not touching, even if that means dropping below it.
        return min(size, chord - 1)
    }

    private func angle(for index: Int, count: Int) -> Double {
        guard count > 1 else { return -45 }
        return arcStart + (arcEnd - arcStart) * Double(index) / Double(count - 1)
    }

    private func buildSatellites(for apps: [NSRunningApplication]) {
        satellites.forEach { $0.removeFromSuperview() }
        satellites.removeAll()

        let count = apps.count
        let size = iconSize(for: count)
        let r = radius(for: count)
        let center = coreCenter

        // The base angle table always sweeps "right and down"; mirror it per
        // axis so the arc opens away from whichever corner the core sits in.
        let xFlip: CGFloat = corner.isRight ? -1 : 1
        let yFlip: CGFloat = corner.isBottom ? -1 : 1

        arcTrackView.update(
            center: center,
            radius: (coreSize / 2 + r) / 2,
            arcStart: arcStart,
            arcEnd: arcEnd,
            xFlip: xFlip,
            yFlip: yFlip
        )

        for (index, app) in apps.enumerated() {
            let icon = AppIconView(app: app, size: size)
            let rad = angle(for: index, count: count) * .pi / 180
            icon.targetOrigin = NSPoint(
                x: center.x + xFlip * r * CGFloat(cos(rad)) - size / 2,
                y: center.y + yFlip * r * CGFloat(sin(rad)) - size / 2
            )
            icon.alphaValue = 0
            icon.setFrameOrigin(NSPoint(x: center.x - size / 2, y: center.y - size / 2))
            icon.onForceQuit = { [weak self] view in self?.removeSatellite(view) }
            addSubview(icon)
            icon.setScale(0.35, duration: 0, animated: false)
            satellites.append(icon)
        }
    }

    /// Fades the icon of a just-killed app out of the arc. The remaining
    /// icons keep their places — the arc re-lays out on the next open.
    private func removeSatellite(_ icon: AppIconView) {
        satellites.removeAll { $0 === icon }
        icon.setScale(0.4, duration: 0.18, timing: collapseTiming)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = collapseTiming
            icon.animator().alphaValue = 0
        }, completionHandler: {
            icon.removeFromSuperview()
        })
    }

    private func expand() {
        guard !isExpanded else { return }
        let apps = RecentAppsTracker.shared.recentApps
        guard !apps.isEmpty else { return }

        isExpanded = true
        generation += 1
        let gen = generation

        resizeWindow(to: Self.expandedSize)
        buildSatellites(for: apps)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = expandTiming
            arcTrackView.animator().alphaValue = 1
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        coreView.layer?.setAffineTransform(CGAffineTransform(scaleX: 1.06, y: 1.06))
        CATransaction.commit()

        for (index, icon) in satellites.enumerated() {
            let delay = Double(index) * 0.035
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == gen else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.36
                    ctx.timingFunction = self.expandTiming
                    icon.animator().setFrameOrigin(icon.targetOrigin)
                    icon.animator().alphaValue = 1
                }
                icon.setScale(1.0, duration: 0.36, timing: self.expandTiming)
            }
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        generation += 1
        let gen = generation

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        coreView.layer?.setAffineTransform(.identity)
        CATransaction.commit()

        let center = coreCenter
        for icon in satellites {
            icon.setScale(0.4, duration: 0.24, timing: collapseTiming)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = collapseTiming
            arcTrackView.animator().alphaValue = 0
            for icon in satellites {
                icon.animator().setFrameOrigin(NSPoint(
                    x: center.x - icon.frame.width / 2,
                    y: center.y - icon.frame.height / 2
                ))
                icon.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            guard let self, self.generation == gen else { return }
            self.satellites.forEach { $0.removeFromSuperview() }
            self.satellites.removeAll()
            self.resizeWindow(to: Self.collapsedSize)
        })
    }

    /// Grows/shrinks the window while keeping whichever edges border the
    /// current corner fixed, so the core never appears to shift on screen.
    private func resizeWindow(to size: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        let oldWidth = frame.width
        let oldHeight = frame.height
        frame.size = NSSize(width: size, height: size)
        if corner.isRight { frame.origin.x += oldWidth - size }
        if !corner.isBottom { frame.origin.y += oldHeight - size }
        window.setFrame(frame, display: true)
    }

    override func mouseDown(with event: NSEvent) {
        isDraggingCore = coreRect.contains(convert(event.locationInWindow, from: nil))
        guard isDraggingCore else { return }
        collapseWork?.cancel()
        collapse()
        dragStartMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        // Never move the window from a stray/misrouted event — only a drag
        // that genuinely began on the core circle may reposition it.
        guard isDraggingCore, let window else { return }
        // Moving by increments off the window's *current* origin, rather than
        // off one captured at mouseDown: collapse() finishes mid-drag and
        // resizeWindow shifts the origin by 174pt to pin the corner edge, and
        // a captured origin would then yank the wheel back by that much.
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouse.x
        let dy = current.y - dragStartMouse.y
        dragStartMouse = current
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingCore {
            snapToNearestCorner()
        }
        isDraggingCore = false
    }

    /// Drag ends here, always — the wheel only ever rests in one of the four
    /// screen corners, never mid-edge or centered.
    private func snapToNearestCorner() {
        guard let window else { return }
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        corner = WheelCorner.nearest(to: NSPoint(x: window.frame.midX, y: window.frame.midY), in: screenFrame)

        let margin: CGFloat = 12
        let size = Self.collapsedSize
        let targetOrigin = NSPoint(
            x: corner.isRight ? screenFrame.maxX - size - margin : screenFrame.minX + margin,
            y: corner.isBottom ? screenFrame.minY + margin : screenFrame.maxY - size - margin
        )

        let newCoreCenter = coreCenter
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(NSRect(origin: targetOrigin, size: NSSize(width: size, height: size)), display: true)
            coreView.animator().setFrameOrigin(NSPoint(
                x: newCoreCenter.x - coreView.frame.width / 2,
                y: newCoreCenter.y - coreView.frame.height / 2
            ))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard coreRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "الإعدادات", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "إنهاء نَقْلة", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: event.locationInWindow, in: self)
    }

    /// The wheel has no Dock icon or menu bar to hang a settings item off of,
    /// so this notification is the bridge to AppDelegate, which owns the
    /// settings window.
    @objc private func openSettings() {
        NotificationCenter.default.post(name: .naqlaOpenSettingsRequested, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Carbon's global hotkey API — works system-wide without needing
/// Accessibility/Input Monitoring permission, unlike NSEvent global monitors.
private var hotKeyToggleHandler: (() -> Void)?

private func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    hotKeyToggleHandler?()
    return noErr
}

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    func register(keyCode: UInt32, modifiers: UInt32, toggle: @escaping () -> Void) {
        hotKeyToggleHandler = toggle

        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, nil)
            handlerInstalled = true
        }

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D57484B), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

/// A click-to-record shortcut field, the same interaction as System
/// Settings' own shortcut recorders: click, press a combo with at least one
/// modifier, done.
final class KeyRecorderView: NSView {
    var onChange: ((UInt32, UInt32) -> Void)?

    private var keyCode: UInt32
    private var modifiers: UInt32
    private var isRecording = false {
        didSet { refresh() }
    }
    private let label = NSTextField(labelWithString: "")

    private static let keyNames: [UInt32: String] = {
        var map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_Space): "Space",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        ]
        return map
    }()

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true

        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(startRecording))
        addGestureRecognizer(click)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { NSSound.beep(); return }

        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbonModifiers(from: mods)
        isRecording = false
        onChange?(keyCode, modifiers)
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private func refresh() {
        layer?.borderWidth = 1
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).cgColor
        label.stringValue = isRecording ? "اضغط تركيبة…" : Self.symbolString(keyCode: keyCode, modifiers: modifiers)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func symbolString(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyNames[keyCode] ?? "?"
        return s
    }
}

/// The real settings UI: everything that used to be a hardcoded constant
/// (hotkey, app count, icon size, accent color, opacity, login item) lives
/// here now, editable like any normal Mac app's preferences window.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "إعدادات نَقْلة"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI(in: window)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func buildUI(in window: NSWindow) {
        let settings = SettingsStore.shared
        let content = NSView()
        content.userInterfaceLayoutDirection = .rightToLeft
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
        ])

        let heading = NSTextField(labelWithString: "إعدادات نَقْلة")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(heading)

        // Hotkey
        let recorder = KeyRecorderView(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        recorder.onChange = { code, mods in
            settings.hotKeyCode = code
            settings.hotKeyModifiers = mods
        }
        stack.addArrangedSubview(row("اختصار الإظهار/الإخفاء:", recorder))

        // Max apps
        let maxAppsField = NSTextField(labelWithString: "\(settings.maxApps)")
        maxAppsField.translatesAutoresizingMaskIntoConstraints = false
        maxAppsField.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let stepper = NSStepper()
        stepper.minValue = 4
        stepper.maxValue = 14
        stepper.integerValue = settings.maxApps
        stepper.target = self
        stepper.action = #selector(maxAppsChanged(_:))
        self.maxAppsField = maxAppsField
        let stepperRow = NSStackView(views: [stepper, maxAppsField])
        stepperRow.spacing = 8
        stack.addArrangedSubview(row("أقصى عدد تطبيقات:", stepperRow))

        // Icon scale
        let iconSlider = NSSlider(value: settings.iconScale, minValue: 0.7, maxValue: 1.3, target: self, action: #selector(iconScaleChanged(_:)))
        iconSlider.translatesAutoresizingMaskIntoConstraints = false
        iconSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(row("حجم الأيقونات:", iconSlider))

        // Accent color
        let colorWell = NSColorWell()
        colorWell.color = settings.accentColor
        colorWell.target = self
        colorWell.action = #selector(accentColorChanged(_:))
        stack.addArrangedSubview(row("لون العجلة:", colorWell))

        // Opacity
        let opacitySlider = NSSlider(value: settings.wheelOpacity, minValue: 0.5, maxValue: 1.0, target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(row("شفافية العجلة:", opacitySlider))

        // Launch at login
        let loginCheckbox = NSButton(checkboxWithTitle: "تشغيل تلقائي عند تسجيل الدخول", target: self, action: #selector(launchAtLoginChanged(_:)))
        loginCheckbox.state = settings.launchAtLogin ? .on : .off
        stack.addArrangedSubview(loginCheckbox)

        let quitButton = NSButton(title: "إنهاء نَقْلة", target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        stack.addArrangedSubview(quitButton)
    }

    private var maxAppsField: NSTextField?

    @objc private func maxAppsChanged(_ sender: NSStepper) {
        SettingsStore.shared.maxApps = sender.integerValue
        maxAppsField?.stringValue = "\(sender.integerValue)"
    }

    @objc private func iconScaleChanged(_ sender: NSSlider) {
        SettingsStore.shared.iconScale = sender.doubleValue
    }

    @objc private func accentColorChanged(_ sender: NSColorWell) {
        SettingsStore.shared.accentColor = sender.color
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        SettingsStore.shared.wheelOpacity = sender.doubleValue
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        SettingsStore.shared.launchAtLogin = sender.state == .on
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSPanel!
    private let hotKey = GlobalHotKey()
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        RecentAppsTracker.shared.start()
        migrateLoginItemIfNeeded()

        let size = WheelContainerView.collapsedSize
        let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.minX + 12, y: visible.maxY - size - 12)

        window = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = CGFloat(SettingsStore.shared.wheelOpacity)

        window.contentView = WheelContainerView(
            frame: NSRect(origin: .zero, size: NSSize(width: size, height: size))
        )

        // Starts hidden — only the configured hotkey brings it on screen.
        registerHotKey()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .naqlaSettingsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettingsRequested), name: .naqlaOpenSettingsRequested, object: nil
        )
    }

    private var lastHotKeyCode: UInt32?
    private var lastHotKeyModifiers: UInt32?

    private func registerHotKey() {
        let settings = SettingsStore.shared
        lastHotKeyCode = settings.hotKeyCode
        lastHotKeyModifiers = settings.hotKeyModifiers
        hotKey.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) { [weak self] in
            self?.toggleWindow()
        }
    }

    @objc private func settingsChanged() {
        let settings = SettingsStore.shared
        if settings.hotKeyCode != lastHotKeyCode || settings.hotKeyModifiers != lastHotKeyModifiers {
            registerHotKey()
        }
    }

    @objc private func openSettingsRequested() {
        showSettings()
    }

    /// One-time move from the old `~/Library/LaunchAgents` plist to a proper
    /// SMAppService login item, so "launch at login" is toggleable from the
    /// settings window and shows up in System Settings like a real app.
    private func migrateLoginItemIfNeeded() {
        let key = "didMigrateLoginItemToSMAppService"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            LoginItem.setEnabled(true)
        }
        removeLegacyLaunchAgentIfNeeded()
    }

    /// The migration above registers SMAppService but never retired the
    /// original ~/Library/LaunchAgents plist that predates it — so both were
    /// still set to RunAtLoad, meaning two Naqla processes at every login.
    /// Guarded separately (and re-checked every launch) since it needs to
    /// run once more even on installs where the migration above already flipped
    /// its own flag before this fix existed.
    private func removeLegacyLaunchAgentIfNeeded() {
        let key = "didRemoveLegacyLaunchAgentPlist"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let path = NSHomeDirectory() + "/Library/LaunchAgents/com.omar.naqla.plist"
        guard FileManager.default.fileExists(atPath: path) else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", path]
        try? unload.run()
        unload.waitUntilExit()

        try? FileManager.default.removeItem(atPath: path)
        UserDefaults.standard.set(true, forKey: key)
    }

    private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Fires when the user double-clicks Naqla's icon while it's already
    /// running — that's the entry point into the settings window, since the
    /// wheel itself has no Dock icon or menu to open one from.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
