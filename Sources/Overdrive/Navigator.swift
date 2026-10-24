import AppKit
import SwiftUI

final class Navigator: NSResponder {
    var available: () -> (back: Bool, forward: Bool) = { (false, false) }
    var progress: (CGFloat) -> Void = { _ in }
    var go: (_ back: Bool, _ source: String) -> Void = { _, _ in }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        axis == .horizontal
    }

    override func scrollWheel(with event: NSEvent) {
        let (back, forward) = available()
        guard event.phase != [], abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), NSEvent.isSwipeTrackingFromScrollEventsEnabled, back || forward else {
            super.scrollWheel(with: event)
            return
        }

        var committed = false
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: forward ? -1 : 0, max: back ? 1 : 0) { [weak self] amount, phase, complete, _ in
            guard let self else { return }

            if phase == .ended, !committed, amount != 0 {
                committed = true
                go(amount > 0, "swipe")
            }
            progress(committed || complete ? 0 : amount)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: go(true, "mouse")
        case 4: go(false, "mouse")
        default: super.otherMouseDown(with: event)
        }
    }

    override func swipe(with event: NSEvent) {
        guard event.deltaX != 0 else { return super.swipe(with: event) }

        go(event.deltaX > 0, "swipe")
    }
}

struct NavigatorInstaller: NSViewRepresentable {
    let navigator: Navigator

    func makeNSView(context: Context) -> Anchor {
        Anchor(navigator: navigator)
    }

    func updateNSView(_ view: Anchor, context: Context) {}

    final class Anchor: NSView {
        let navigator: Navigator

        init(navigator: Navigator) {
            self.navigator = navigator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.nextResponder !== navigator else { return }

            navigator.nextResponder = window.nextResponder
            window.nextResponder = navigator
        }
    }
}
