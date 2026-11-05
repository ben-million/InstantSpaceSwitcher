import AppKit
import ISS

final class OSDWindow {
  static let shared = OSDWindow()
  private var window: NSWindow?
  private var label: NSTextField?
  private var iconStack: NSStackView?
  private var hideTimer: Timer?

  private static let numberSize: CGFloat = 140
  private static let iconSize: CGFloat = 64
  private static let iconSpacing: CGFloat = 12
  private static let iconPadding: CGFloat = 24
  private static let maxIcons = 8

  private init() {}

  /// Shows the apps with windows on the space, frontmost first, or the space's
  /// number when it has none or app icons are turned off.
  func show(spaceIndex: UInt32) {
    guard shouldShow() else { return }
    present(spaceIndex: spaceIndex, hidesAfterDuration: true)
  }

  func show(message: String) {
    guard shouldShow() else { return }
    present(message: message, hidesAfterDuration: true)
  }

  /// Shows the space the way show(spaceIndex:) does, whatever the on-screen display
  /// settings say, and keeps it up until scheduleHide() or hide().
  func showPreview(spaceIndex: UInt32) {
    present(spaceIndex: spaceIndex, hidesAfterDuration: false)
  }

  /// Hides after the usual on-screen display duration.
  func scheduleHide() {
    hideTimer?.invalidate()
    let durationMs = UserDefaults.standard.object(forKey: "osdDurationMs") as? Int ?? 500
    hideTimer = Timer.scheduledTimer(withTimeInterval: Double(durationMs) / 1000.0, repeats: false) { [weak self] _ in
      self?.hide()
    }
  }

  func hide() {
    hideTimer?.invalidate()
    hideTimer = nil
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.2
      window?.animator().alphaValue = 0.0
    })
  }

  private func shouldShow() -> Bool {
    guard UserDefaults.standard.bool(forKey: "showOSD") else { return false }
    // Mission Control OSD suppression requires overlay detection enabled
    let overlayDetectionEnabled = UserDefaults.standard.bool(forKey: "overlayDetectionEnabled")
    if overlayDetectionEnabled && iss_is_mission_control_active() && !UserDefaults.standard.bool(forKey: "showOSDInMissionControl") {
      return false
    }
    return true
  }

  private func present(spaceIndex: UInt32, hidesAfterDuration: Bool) {
    let showsAppIcons = UserDefaults.standard.object(forKey: "osdShowsAppIcons") as? Bool ?? true
    let icons = showsAppIcons ? Self.appIcons(onSpace: spaceIndex) : []
    if icons.isEmpty {
      present(message: "\(spaceIndex + 1)", hidesAfterDuration: hidesAfterDuration)
    } else {
      present(icons: icons, hidesAfterDuration: hidesAfterDuration)
    }
  }

  private static func appIcons(onSpace spaceIndex: UInt32) -> [NSImage] {
    // Ask for more than fit: helpers and agents drop out below
    var pids = [pid_t](repeating: 0, count: 32)
    let count = Int(iss_get_space_app_pids(spaceIndex, &pids, UInt32(pids.count)))

    var seen = Set<String>()
    var icons: [NSImage] = []
    for pid in pids.prefix(count) {
      guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
        let icon = app.icon
      else { continue }
      // One icon per app, even when it runs as several processes
      guard seen.insert(app.bundleIdentifier ?? "\(pid)").inserted else { continue }
      icons.append(icon)
      if icons.count == maxIcons { break }
    }
    return icons
  }

  private func present(message: String, hidesAfterDuration: Bool) {
    if window == nil {
      createWindow()
    }
    guard let window = window, let label = label, let iconStack = iconStack else { return }

    label.stringValue = message
    label.isHidden = false
    iconStack.isHidden = true
    present(window, size: NSSize(width: Self.numberSize, height: Self.numberSize), hidesAfterDuration: hidesAfterDuration)
  }

  private func present(icons: [NSImage], hidesAfterDuration: Bool) {
    if window == nil {
      createWindow()
    }
    guard let window = window, let label = label, let iconStack = iconStack else { return }

    for view in iconStack.arrangedSubviews {
      iconStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for icon in icons {
      let imageView = NSImageView(image: icon)
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        imageView.widthAnchor.constraint(equalToConstant: Self.iconSize),
        imageView.heightAnchor.constraint(equalToConstant: Self.iconSize),
      ])
      iconStack.addArrangedSubview(imageView)
    }

    label.isHidden = true
    iconStack.isHidden = false
    let count = CGFloat(icons.count)
    let width = count * Self.iconSize + (count - 1) * Self.iconSpacing + 2 * Self.iconPadding
    present(
      window, size: NSSize(width: width, height: Self.iconSize + 2 * Self.iconPadding),
      hidesAfterDuration: hidesAfterDuration)
  }

  private func present(_ window: NSWindow, size: NSSize, hidesAfterDuration: Bool) {
    hideTimer?.invalidate()
    hideTimer = nil

    // Center on cursor's screen
    var frame = NSRect(origin: window.frame.origin, size: size)
    let mouseLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    if let screen = screen {
      let screenFrame = screen.visibleFrame
      frame.origin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
    }
    window.setFrame(frame, display: true)

    window.alphaValue = 1.0
    window.orderFrontRegardless()

    if hidesAfterDuration {
      scheduleHide()
    }
  }

  private func createWindow() {
    let windowSize = Self.numberSize

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: windowSize, height: windowSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    window.ignoresMouseEvents = true
    window.hidesOnDeactivate = false

    // Use vibrancy for native macOS look
    let visualEffect = NSVisualEffectView(
      frame: NSRect(x: 0, y: 0, width: windowSize, height: windowSize))
    visualEffect.material = .hudWindow
    visualEffect.state = .active
    visualEffect.wantsLayer = true
    visualEffect.layer?.cornerRadius = 18
    visualEffect.layer?.masksToBounds = true

    let label = NSTextField(labelWithString: "")
    label.font = NSFont.systemFont(ofSize: 48, weight: .medium)
    label.textColor = .labelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.drawsBackground = false
    label.isBordered = false
    label.isEditable = false

    let iconStack = NSStackView()
    iconStack.orientation = .horizontal
    iconStack.spacing = Self.iconSpacing
    iconStack.translatesAutoresizingMaskIntoConstraints = false
    iconStack.isHidden = true

    visualEffect.addSubview(label)
    visualEffect.addSubview(iconStack)
    window.contentView = visualEffect

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
      iconStack.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
      iconStack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
    ])

    self.window = window
    self.label = label
    self.iconStack = iconStack
  }
}
