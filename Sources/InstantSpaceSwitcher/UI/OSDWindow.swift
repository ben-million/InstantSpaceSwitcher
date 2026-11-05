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
  // Covers the screen behind the icons
  private var scrim: NSWindow?
  // Whether the scrim is meant to be up, which a fade-out checks before taking it down
  private var scrimShown = false
  // The last desktop picture loaded, by its file and frame
  private var wallpaperCache: (key: String, image: CGImage)?

  /// What covers the screen behind the display.
  private enum Backdrop {
    case none
    case fade  // The screen, dimmed
    case wallpaper  // The desktop picture alone, with no windows
  }

  private static let numberSize: CGFloat = 140
  private static let iconSize: CGFloat = 64
  private static let iconSpacing: CGFloat = 12
  private static let iconPadding: CGFloat = 24
  private static let maxIcons = 8
  private static let cornerRadius: CGFloat = 18
  private static let scrimOpacity: CGFloat = 0.3

  // The overview of every space
  private static let tileSize: CGFloat = 192
  private static let cardInset: CGFloat = 16
  private static let cardCornerRadius: CGFloat = 32
  private static let cardSpacing: CGFloat = 4
  private static let overviewPadding: CGFloat = 14

  private init() {}

  /// Shows the apps with windows on the space, frontmost first, or the space's
  /// number when it has none or app icons are turned off.
  func show(spaceIndex: UInt32) {
    guard shouldShow() else { return }
    present(spaceIndex: spaceIndex, hidesAfterDuration: true)
  }

  func show(message: String) {
    guard shouldShow() else { return }
    present(message: message, backdrop: .none, hidesAfterDuration: true)
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
    let backdrop = showsAppIcons ? Self.iconBackdrop() : .none
    if showsAppIcons && defaults.bool(forKey: "osdShowsAllSpaces"), let spaces = allSpacesIcons(),
      Int(spaceIndex) < spaces.count
    {
      present(spaces: spaces, selected: Int(spaceIndex), backdrop: backdrop, hidesAfterDuration: hidesAfterDuration)
      return
    }
    let icons = showsAppIcons ? Self.appIcons(onSpace: spaceIndex) : []
    if icons.isEmpty {
      present(message: "\(spaceIndex + 1)", backdrop: backdrop, hidesAfterDuration: hidesAfterDuration)
    } else {
      present(icons: icons, backdrop: backdrop, hidesAfterDuration: hidesAfterDuration)
    }
  }

  private static func iconBackdrop() -> Backdrop {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "osdShowsOnlyWallpaper") {
      return .wallpaper
    }
    return defaults.object(forKey: "osdFadesScreen") as? Bool ?? true ? .fade : .none
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

  private func present(message: String, backdrop: Backdrop, hidesAfterDuration: Bool) {
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
      window, size: NSSize(width: Self.numberSize, height: Self.numberSize), backdrop: backdrop,
      hidesAfterDuration: hidesAfterDuration)
  }

  private func present(icons: [NSImage], backdrop: Backdrop, hidesAfterDuration: Bool) {
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
      window, size: NSSize(width: width, height: Self.iconSize + 2 * Self.iconPadding), backdrop: backdrop,
      hidesAfterDuration: hidesAfterDuration)
  }

  /// Lays every space out as a tile of its app icons, the way Command-Tab lays out
  /// apps, and sets the selected one on a card.
  private func present(spaces: [[NSImage]], selected: Int, backdrop: Backdrop, hidesAfterDuration: Bool) {
    if window == nil {
      createWindow()
    }
    guard let window, let label, let iconStack, let overview else { return }

    // Smaller tiles when there are too many spaces to fit across the screen
    let count = CGFloat(spaces.count)
    let screenWidth = Self.cursorScreen()?.visibleFrame.width ?? 1440
    let cardSide = min(
      Self.tileSize + 2 * Self.cardInset,
      (screenWidth * 0.9 - 2 * Self.overviewPadding - (count - 1) * Self.cardSpacing) / count)

    for view in overview.arrangedSubviews {
      overview.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for (index, icons) in spaces.enumerated() {
      overview.addArrangedSubview(
        Self.spaceTile(icons: icons, number: index + 1, size: cardSide - 2 * Self.cardInset, selected: index == selected))
    }

    label.isHidden = true
    iconStack.isHidden = true
    overview.isHidden = false
    // Corners that follow the card's, round it
    panel?.layer?.cornerRadius = Self.cardCornerRadius + Self.overviewPadding
    let width = count * cardSide + (count - 1) * Self.cardSpacing + 2 * Self.overviewPadding
    present(
      window, size: NSSize(width: width, height: cardSide + 2 * Self.overviewPadding), backdrop: backdrop,
      hidesAfterDuration: hidesAfterDuration)
  }

  /// One space in the overview: its app icons in a grid as square as they allow, or its
  /// number when it has none, with room around it for the card.
  private static func spaceTile(icons: [NSImage], number: Int, size: CGFloat, selected: Bool) -> NSView {
    let tile = NSView()
    tile.wantsLayer = true
    tile.translatesAutoresizingMaskIntoConstraints = false
    let side = size + 2 * cardInset
    NSLayoutConstraint.activate([
      tile.widthAnchor.constraint(equalToConstant: side),
      tile.heightAnchor.constraint(equalToConstant: side),
    ])
    if selected, let layer = tile.layer {
      layer.cornerRadius = cardCornerRadius
      layer.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
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

  private func present(_ window: NSWindow, size: NSSize, backdrop: Backdrop, hidesAfterDuration: Bool) {
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
    if backdrop != .none, let screen {
      showScrim(over: screen, backdrop: backdrop)
    } else {
      hideScrim()
    }

    window.alphaValue = 1.0
    window.orderFrontRegardless()

    if hidesAfterDuration {
      scheduleHide()
    }
  }

  private func showScrim(over screen: NSScreen, backdrop: Backdrop) {
    let scrim = self.scrim ?? createScrim()
    scrimShown = true
    scrim.setFrame(screen.frame, display: false)
    if let layer = scrim.contentView?.layer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if backdrop == .wallpaper {
        let wallpaper = wallpaper(for: screen)
        layer.contents = wallpaper.image
        layer.contentsGravity = wallpaper.gravity
        layer.contentsScale = screen.backingScaleFactor
        layer.backgroundColor = wallpaper.fillColor.cgColor
      } else {
        layer.contents = nil
        layer.backgroundColor = NSColor.black.cgColor
      }
      CATransaction.commit()
    }
    if !scrim.isVisible {
      // Clear while it's in front of the window, until the window comes forward
      scrim.alphaValue = 0
      scrim.orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      scrim.animator().alphaValue = backdrop == .wallpaper ? 1 : Self.scrimOpacity
    }
  }

  /// The screen's desktop picture as macOS shows it: the light or dark frame of one that
  /// follows the appearance, placed the way the screen's settings say.
  private func wallpaper(for screen: NSScreen) -> (image: CGImage?, gravity: CALayerContentsGravity, fillColor: NSColor) {
    let workspace = NSWorkspace.shared
    let options = workspace.desktopImageOptions(for: screen) ?? [:]
    let fillColor = options[.fillColor] as? NSColor ?? .black
    let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
    let allowsClipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
    let gravity: CALayerContentsGravity
    switch scaling {
    case .scaleAxesIndependently: gravity = .resize
    case .scaleNone: gravity = .center
    default: gravity = allowsClipping ? .resizeAspectFill : .resizeAspect
    }

    guard let url = workspace.desktopImageURL(for: screen),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    else { return (nil, gravity, fillColor) }
    let index = Self.appearanceFrame(of: source) ?? CGImageSourceGetPrimaryImageIndex(source)
    let key = "\(url.path)#\(index)"
    if let wallpaperCache, wallpaperCache.key == key {
      return (wallpaperCache.image, gravity, fillColor)
    }
    let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    if let image {
      wallpaperCache = (key, image)
    }
    return (image, gravity, fillColor)
  }

  /// For a desktop picture with a frame for light and one for dark, the one the
  /// appearance is using, from the index in its apple_desktop:apr metadata.
  private static func appearanceFrame(of source: CGImageSource) -> Int? {
    let primary = CGImageSourceGetPrimaryImageIndex(source)
    guard let metadata = CGImageSourceCopyMetadataAtIndex(source, primary, nil),
      let encoded = CGImageMetadataCopyStringValueWithPath(metadata, nil, "apple_desktop:apr" as CFString) as String?,
      let data = Data(base64Encoded: encoded),
      let frames = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Int]
    else { return nil }
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return frames[isDark ? "d" : "l"]
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

    // A layer this window owns, whose colour or picture a whole screen of needs no drawing
    let shade = NSView()
    shade.layer = CALayer()
    shade.wantsLayer = true
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
    overview.spacing = Self.cardSpacing
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
