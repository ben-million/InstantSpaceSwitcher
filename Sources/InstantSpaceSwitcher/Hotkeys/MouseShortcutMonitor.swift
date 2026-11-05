import AppKit
import ISS

/// Command-Control-click switches spaces: the left button one space to the left,
/// the right button one space to the right. A shortcut click never reaches the
/// window under the pointer.
///
/// Command-Control-drag still moves windows (AppKit's NSWindowShouldDragOnGesture),
/// so a left press is held back until it ends as a click, which switches on release,
/// or moves far enough to be a drag, which gets its press back. The right button
/// has no drag to protect and switches on the press.
final class MouseShortcutMonitor {
  static let shared = MouseShortcutMonitor()

  /// Called on the main queue with the direction of each shortcut click.
  var handler: ((ISSDirection) -> Void)?

  private enum LeftPress {
    case none
    case held(CGEvent)
    case dragging
  }

  /// How far a held press may move, in points, and still count as a click.
  private static let dragThreshold: CGFloat = 4
  /// Marks events this monitor posts itself, in their source user data, so it lets them pass.
  private static let replayMarker: Int64 = 0x4953_5343  // "ISSC"

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var retryScheduled = false
  private var isEnabled = false

  private var leftPress = LeftPress.none
  // A swallowed right press must take its drags and its release with it
  private var swallowingRight = false

  private init() {}

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    if enabled {
      installEventTap()
    } else {
      removeEventTap()
    }
  }

  private func installEventTap() {
    if let eventTap {
      if CFMachPortIsValid(eventTap) {
        return
      }
      self.eventTap = nil
      runLoopSource = nil
    }

    let eventTypes: [CGEventType] = [
      .leftMouseDown, .leftMouseDragged, .leftMouseUp,
      .rightMouseDown, .rightMouseDragged, .rightMouseUp,
    ]
    let eventMask = eventTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: { _, type, event, userInfo in
          guard let userInfo else { return Unmanaged.passUnretained(event) }
          let monitor = Unmanaged<MouseShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Releases may have gone by while the tap was off
            monitor.resetPresses()
            if let eventTap = monitor.eventTap {
              CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
          }

          if monitor.swallow(type: type, event: event) {
            return nil
          }
          return Unmanaged.passUnretained(event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      print("Failed to install mouse shortcut event tap")
      scheduleEventTapRetry()
      return
    }

    retryScheduled = false
    self.eventTap = eventTap
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    if let runLoopSource {
      CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  private func removeEventTap() {
    resetPresses()
    guard let eventTap else { return }

    CGEvent.tapEnable(tap: eventTap, enable: false)
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    CFMachPortInvalidate(eventTap)
    self.eventTap = nil
    runLoopSource = nil
  }

  private func scheduleEventTapRetry() {
    guard !retryScheduled else { return }
    retryScheduled = true

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self else { return }
      self.retryScheduled = false
      if self.isEnabled {
        self.installEventTap()
      }
    }
  }

  private func resetPresses() {
    leftPress = .none
    swallowingRight = false
  }

  /// Returns true when the event belongs to a shortcut click and must not reach apps.
  private func swallow(type: CGEventType, event: CGEvent) -> Bool {
    // A press and drag handed back to a window come round again
    if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
      return false
    }

    switch type {
    case .leftMouseDown:
      guard Self.isShortcut(event.flags), let press = event.copy() else {
        leftPress = .none
        return false
      }
      leftPress = .held(press)
      return true

    case .leftMouseDragged:
      guard case .held(let press) = leftPress else { return false }
      if Self.distance(event.location, press.location) < Self.dragThreshold {
        return true
      }
      // A drag after all: give the window its press, then this drag, in order
      leftPress = .dragging
      Self.replay(press)
      if let drag = event.copy() {
        Self.replay(drag)
      }
      return true

    case .leftMouseUp:
      guard case .held = leftPress else {
        leftPress = .none
        return false
      }
      leftPress = .none
      fire(ISSDirectionLeft)
      return true

    case .rightMouseDown:
      swallowingRight = Self.isShortcut(event.flags)
      if swallowingRight { fire(ISSDirectionRight) }
      return swallowingRight

    case .rightMouseDragged:
      return swallowingRight

    case .rightMouseUp:
      let swallowed = swallowingRight
      swallowingRight = false
      return swallowed

    default:
      return false
    }
  }

  private func fire(_ direction: ISSDirection) {
    DispatchQueue.main.async { [weak self] in
      self?.handler?(direction)
    }
  }

  private static func replay(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
    event.post(tap: .cgSessionEventTap)
  }

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
  }

  /// Exactly Command and Control, so Command-Control-Option-click and the like pass through.
  private static func isShortcut(_ flags: CGEventFlags) -> Bool {
    let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    return flags.intersection(modifiers) == [.maskCommand, .maskControl]
  }
}
