import AppKit
import ISS

/// Command-Control-click switches spaces: the left button one space to the left,
/// the right button one space to the right. A shortcut click never reaches the
/// window under the pointer.
///
/// Command-scroll, with Control or without, steps the same way, as the scroll would
/// move a page: back (up or left) one space left, forward (down or right) one space
/// right. A mouse wheel steps once a notch. On a trackpad or Magic Mouse the fingers
/// step as soon as they move, then again every so far they scroll; the momentum after
/// they lift doesn't step, so the spaces stop where the fingers do.
///
/// Command-Control-drag still moves windows (AppKit's NSWindowShouldDragOnGesture),
/// so a left press is held back until it ends as a click, which switches on release,
/// or moves far enough to be a drag, which gets its press back. The right button
/// has no drag to protect and switches on the press.
final class MouseShortcutMonitor {
  static let shared = MouseShortcutMonitor()

  /// Called on the main queue with the direction of each shortcut click or scroll.
  var handler: ((ISSDirection) -> Void)?

  private enum LeftPress {
    case none
    case held(CGEvent)
    case dragging
  }

  /// A trackpad or Magic Mouse scroll, from the fingers coming down to the end of its
  /// momentum. Whether it's a shortcut is settled as it starts, so no app gets part of one.
  private enum Swipe {
    case passing
    // A shortcut: how far forward the fingers have scrolled since its last step, and whether it has stepped
    case stepping(Double, Bool)
  }

  /// How far a held press may move, in points, and still count as a click.
  private static let dragThreshold: CGFloat = 4
  /// How far a swipe scrolls, in points, to its first step, and between steps after that.
  private static let swipeFirstStep: Double = 10
  private static let swipeStep: Double = 60
  /// Marks events this monitor posts itself, in their source user data, so it lets them pass.
  private static let replayMarker: Int64 = 0x4953_5343  // "ISSC"

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var retryScheduled = false
  private var isEnabled = false

  private var leftPress = LeftPress.none
  // A swallowed right press must take its drags and its release with it
  private var swallowingRight = false
  private var swipe = Swipe.passing
  // Fingers came down with the shortcut held, and their swipe hasn't begun
  private var shortcutTouch = false

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
      .scrollWheel,
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
            // Releases and the ends of swipes may have gone by while the tap was off
            monitor.resetGestures()
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
    resetGestures()
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

  private func resetGestures() {
    leftPress = .none
    swallowingRight = false
    swipe = .passing
    shortcutTouch = false
  }

  /// Returns true when the event belongs to a shortcut click or scroll and must not reach apps.
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

    case .scrollWheel:
      return swallowScroll(event)

    default:
      return false
    }
  }

  private func swallowScroll(_ event: CGEvent) -> Bool {
    let phase = UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
    let momentumPhase = UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase))

    // A mouse wheel's scrolls have no phases
    if phase == 0 && momentumPhase == CGMomentumScrollPhase.none.rawValue {
      guard Self.isScrollShortcut(event.flags) else { return false }
      let forward = Self.forward(
        dx: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
        dy: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
      if forward != 0 { fire(forward > 0 ? ISSDirectionRight : ISSDirectionLeft) }
      return true
    }

    switch phase {
    case CGScrollPhase.mayBegin.rawValue:
      shortcutTouch = Self.isScrollShortcut(event.flags)
      swipe = shortcutTouch ? .stepping(0, false) : .passing
    case CGScrollPhase.began.rawValue:
      // A touch that came down as a shortcut stays one
      if !shortcutTouch {
        swipe = Self.isScrollShortcut(event.flags) ? .stepping(0, false) : .passing
      }
      shortcutTouch = false
    case CGScrollPhase.ended.rawValue, CGScrollPhase.cancelled.rawValue:
      shortcutTouch = false
    default:
      break
    }

    guard case .stepping(var travel, var hasStepped) = swipe else { return false }
    if momentumPhase == CGMomentumScrollPhase.none.rawValue {
      travel += Self.forward(
        dx: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
        dy: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)))
      var step = hasStepped ? Self.swipeStep : Self.swipeFirstStep
      while abs(travel) >= step {
        fire(travel > 0 ? ISSDirectionRight : ISSDirectionLeft)
        travel -= travel > 0 ? step : -step
        hasStepped = true
        step = Self.swipeStep
      }
      swipe = .stepping(travel, hasStepped)
    }
    return true
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

  /// How far a scroll goes forward, which moves a page down or right and steps a space
  /// to the right; back is negative. The deltas already follow the natural scrolling setting.
  private static func forward(dx: Double, dy: Double) -> Double {
    -(abs(dx) > abs(dy) ? dx : dy)
  }

  /// Exactly Command and Control, so Command-Control-Option-click and the like pass through.
  private static func isShortcut(_ flags: CGEventFlags) -> Bool {
    let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    return flags.intersection(modifiers) == [.maskCommand, .maskControl]
  }

  /// Command, with Control or without, but not Option or Shift, so Command-Shift-scroll and
  /// the like pass through.
  private static func isScrollShortcut(_ flags: CGEventFlags) -> Bool {
    let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    return modifiers == [.maskCommand] || modifiers == [.maskCommand, .maskControl]
  }
}
