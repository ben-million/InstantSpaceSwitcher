import AppKit
import ISS

final class OSDWindow {
  static let shared = OSDWindow()
  private var window: NSWindow?
  private var panel: NSVisualEffectView?
  private var label: NSTextField?
  private var iconStack: NSStackView?
  private var overview: NSStackView?
  // Every space's icons, and the display they're on, while the display is up
  private var overviewCache: (display: String, spaces: [[NSImage]])?
  private var hideTimer: Timer?
  // Fades the screen behind the icons
  private var scrim: NSWindow?
  // Whether the scrim is meant to be up, which a fade-out checks before taking it down
  private var scrimShown = false

  private static let numberSize: CGFloat = 140
  private static let iconSize: CGFloat = 64
  private static let iconSpacing: CGFloat = 12
  private static let iconPadding: CGFloat = 24
  private static let maxIcons = 8
  private static let cornerRadius: CGFloat = 18
  private static let scrimOpacity: CGFloat = 0.3

  // The overview of every space
  private static let tileSize: CGFloat = 96
  private static let ringInset: CGFloat = 10
  private static let ringWidth: CGFloat = 3
  private static let ringCornerRadius: CGFloat = 16
  private static let ringSpacing: CGFloat = 4
  private static let overviewPadding: CGFloat = 12

  private init() {}

  /// Shows the apps with windows on the space, frontmost first, or the space's
  /// number when it has none or app icons are turned off.
  func show(spaceIndex: UInt32) {
    guard shouldShow() else { return }
    present(spaceIndex: spaceIndex, hidesAfterDuration: true)
  }

  func show(message: String) {
    guard shouldShow() else { return }
    present(message: message, fadesScreen: false, hidesAfterDuration: true)
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
    overviewCache = nil
    hideScrim()
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
    let defaults = UserDefaults.standard
    let showsAppIcons = defaults.object(forKey: "osdShowsAppIcons") as? Bool ?? true
    // Behind an empty space's number too, so stepping through spaces doesn't flicker
    let fadesScreen = showsAppIcons && (defaults.object(forKey: "osdFadesScreen") as? Bool ?? true)
    if showsAppIcons && defaults.bool(forKey: "osdShowsAllSpaces"), let spaces = allSpacesIcons(),
      Int(spaceIndex) < spaces.count
    {
      present(spaces: spaces, selected: Int(spaceIndex), fadesScreen: fadesScreen, hidesAfterDuration: hidesAfterDuration)
      return
    }
    let icons = showsAppIcons ? Self.appIcons(onSpace: spaceIndex) : []
    if icons.isEmpty {
      present(message: "\(spaceIndex + 1)", fadesScreen: fadesScreen, hidesAfterDuration: hidesAfterDuration)
    } else {
      present(icons: icons, fadesScreen: fadesScreen, hidesAfterDuration: hidesAfterDuration)
    }
  }

  /// Every space's app icons on the display under the cursor. They're kept while the
  /// display is up, as stepping from space to space doesn't change what's on them.
  private func allSpacesIcons() -> [[NSImage]]? {
    var info = ISSSpaceInfo()
    guard iss_get_space_info(&info), info.spaceCount > 0 else { return nil }
    let display = withUnsafeBytes(of: info.displayID) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    if let overviewCache, overviewCache.display == display, overviewCache.spaces.count == Int(info.spaceCount) {
      return overviewCache.spaces
    }
    let spaces = (0..<info.spaceCount).map { Self.appIcons(onSpace: $0) }
    overviewCache = (display, spaces)
    return spaces
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

  private func present(message: String, fadesScreen: Bool, hidesAfterDuration: Bool) {
    if window == nil {
      createWindow()
    }
    guard let window = window, let label = label, let iconStack = iconStack, let overview else { return }

    label.stringValue = message
    label.isHidden = false
    iconStack.isHidden = true
    overview.isHidden = true
    panel?.layer?.cornerRadius = Self.cornerRadius
    present(
      window, size: NSSize(width: Self.numberSize, height: Self.numberSize), fadesScreen: fadesScreen,
      hidesAfterDuration: hidesAfterDuration)
  }

  private func present(icons: [NSImage], fadesScreen: Bool, hidesAfterDuration: Bool) {
    if window == nil {
      createWindow()
    }
    guard let window = window, let label = label, let iconStack = iconStack, let overview else { return }

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
    overview.isHidden = true
    panel?.layer?.cornerRadius = Self.cornerRadius
    let count = CGFloat(icons.count)
    let width = count * Self.iconSize + (count - 1) * Self.iconSpacing + 2 * Self.iconPadding
    present(
      window, size: NSSize(width: width, height: Self.iconSize + 2 * Self.iconPadding), fadesScreen: fadesScreen,
      hidesAfterDuration: hidesAfterDuration)
  }

  /// Lays every space out as a tile of its app icons, the way Command-Tab lays out
  /// apps, and rings the selected one.
  private func present(spaces: [[NSImage]], selected: Int, fadesScreen: Bool, hidesAfterDuration: Bool) {
    if window == nil {
      createWindow()
    }
    guard let window, let label, let iconStack, let overview else { return }

    // Smaller tiles when there are too many spaces to fit across the screen
    let count = CGFloat(spaces.count)
    let screenWidth = Self.cursorScreen()?.visibleFrame.width ?? 1440
    let ringSide = min(
      Self.tileSize + 2 * Self.ringInset,
      (screenWidth * 0.9 - 2 * Self.overviewPadding - (count - 1) * Self.ringSpacing) / count)

    for view in overview.arrangedSubviews {
      overview.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for (index, icons) in spaces.enumerated() {
      overview.addArrangedSubview(
        Self.spaceTile(icons: icons, number: index + 1, size: ringSide - 2 * Self.ringInset, ringed: index == selected))
    }

    label.isHidden = true
    iconStack.isHidden = true
    overview.isHidden = false
    // Corners that follow the ring's, round it
    panel?.layer?.cornerRadius = Self.ringCornerRadius + Self.overviewPadding
    let width = count * ringSide + (count - 1) * Self.ringSpacing + 2 * Self.overviewPadding
    present(
      window, size: NSSize(width: width, height: ringSide + 2 * Self.overviewPadding), fadesScreen: fadesScreen,
      hidesAfterDuration: hidesAfterDuration)
  }

  /// One space in the overview: its app icons in a grid as square as they allow, or its
  /// number when it has none, with room around it for the ring.
  private static func spaceTile(icons: [NSImage], number: Int, size: CGFloat, ringed: Bool) -> NSView {
    let tile = NSView()
    tile.wantsLayer = true
    tile.translatesAutoresizingMaskIntoConstraints = false
    let side = size + 2 * ringInset
    NSLayoutConstraint.activate([
      tile.widthAnchor.constraint(equalToConstant: side),
      tile.heightAnchor.constraint(equalToConstant: side),
    ])
    if ringed, let layer = tile.layer {
      layer.cornerRadius = ringCornerRadius
      layer.borderWidth = ringWidth
      layer.borderColor = NSColor.white.cgColor
      layer.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
    }

    let content: NSView
    if icons.isEmpty {
      let label = NSTextField(labelWithString: "\(number)")
      label.font = NSFont.systemFont(ofSize: size * 0.4, weight: .medium)
      label.textColor = .secondaryLabelColor
      content = label
    } else {
      let columns = Int(ceil(Double(icons.count).squareRoot()))
      let gap = size * 0.06
      let iconSide = (size - CGFloat(columns - 1) * gap) / CGFloat(columns)
      let rows = NSStackView()
      rows.orientation = .vertical
      rows.alignment = .centerX
      rows.spacing = gap
      for start in stride(from: 0, to: icons.count, by: columns) {
        let row = NSStackView(
          views: icons[start..<min(start + columns, icons.count)].map { icon in
            let imageView = NSImageView(image: icon)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
              imageView.widthAnchor.constraint(equalToConstant: iconSide),
              imageView.heightAnchor.constraint(equalToConstant: iconSide),
            ])
            return imageView
          })
        row.spacing = gap
        rows.addArrangedSubview(row)
      }
      content = rows
    }
    content.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(content)
    NSLayoutConstraint.activate([
      content.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      content.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
    ])
    return tile
  }

  private static func cursorScreen() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
  }

  private func present(_ window: NSWindow, size: NSSize, fadesScreen: Bool, hidesAfterDuration: Bool) {
    hideTimer?.invalidate()
    hideTimer = nil

    // Center on cursor's screen
    var frame = NSRect(origin: window.frame.origin, size: size)
    let screen = Self.cursorScreen()
    if let screen = screen {
      let screenFrame = screen.visibleFrame
      frame.origin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
    }
    window.setFrame(frame, display: true)

    // Before the window comes forward, so the scrim stays beneath it
    if fadesScreen, let screen {
      showScrim(over: screen)
    } else {
      hideScrim()
    }

    window.alphaValue = 1.0
    window.orderFrontRegardless()

    if hidesAfterDuration {
      scheduleHide()
    }
  }

  private func showScrim(over screen: NSScreen) {
    let scrim = self.scrim ?? createScrim()
    scrimShown = true
    scrim.setFrame(screen.frame, display: false)
    if !scrim.isVisible {
      // Clear while it's in front of the window, until the window comes forward
      scrim.alphaValue = 0
      scrim.orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      scrim.animator().alphaValue = Self.scrimOpacity
    }
  }

  private func hideScrim() {
    guard scrimShown, let scrim else { return }
    scrimShown = false
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.2
        scrim.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        // Showing it again cuts the fade short, and this still runs
        if self?.scrimShown == false {
          scrim.orderOut(nil)
        }
      })
  }

  private func createScrim() -> NSWindow {
    let scrim = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    scrim.isReleasedWhenClosed = false
    scrim.isOpaque = false
    scrim.backgroundColor = .clear
    scrim.hasShadow = false
    scrim.level = .statusBar
    scrim.collectionBehavior = [.canJoinAllSpaces, .stationary]
    scrim.ignoresMouseEvents = true
    scrim.hidesOnDeactivate = false
    // Gone as soon as it's ordered out, without shrinking away first
    scrim.animationBehavior = .none

    // A layer's colour, so a whole screen of it needs no drawing
    let shade = NSView()
    shade.wantsLayer = true
    shade.layer?.backgroundColor = NSColor.black.cgColor
    scrim.contentView = shade

    self.scrim = scrim
    return scrim
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
    visualEffect.layer?.cornerRadius = Self.cornerRadius
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

    let overview = NSStackView()
    overview.orientation = .horizontal
    overview.spacing = Self.ringSpacing
    overview.translatesAutoresizingMaskIntoConstraints = false
    overview.isHidden = true

    visualEffect.addSubview(label)
    visualEffect.addSubview(iconStack)
    visualEffect.addSubview(overview)
    window.contentView = visualEffect

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
      iconStack.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
      iconStack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
      overview.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
      overview.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
    ])

    self.window = window
    self.panel = visualEffect
    self.label = label
    self.iconStack = iconStack
    self.overview = overview
  }
}
