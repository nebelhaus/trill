import AppKit
import SwiftUI

/// An `NSTextView` that reports the height its text wants and routes Return
/// through the composer's send policy. SwiftUI clamps the reported height
/// between one line and the caller's ceiling; past the ceiling the scroll view
/// takes over, so a long draft scrolls in place instead of shoving the box up.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    /// Natural (unclamped) height of the laid-out text; the caller clamps it.
    @Binding var measuredHeight: CGFloat
    var fontSize: CGFloat
    var isEnabled: Bool
    /// `true` → Return sends, Shift+Return inserts a newline. `false` → Return
    /// inserts a newline, ⌘Return sends.
    var sendOnReturn: Bool
    /// Only true once the box is pinned at its max height — below that it grows
    /// to fit, so the scroller stays hidden and never flashes mid-growth.
    var isScrollable: Bool
    /// When the completion picker is open, ↑/↓ move its selection, Return/Tab
    /// commit the highlighted command or snippet, and Escape dismisses it — all
    /// before the normal Return-to-send policy runs.
    var isCompletionPickerActive = false
    var onCompletionMove: (Int) -> Void = { _ in }
    /// Returns `true` when a completion was inserted, so the key is consumed.
    var onCompletionCommit: () -> Bool = { false }
    var onCompletionCancel: () -> Void = {}
    /// A one-shot request to select a range (a template blank). Applied once per
    /// distinct `token`, after any text sync, so the highlight survives the
    /// caret-park that follows a programmatic string change.
    var pendingSelection: ComposerModel.PendingSelection?
    /// While filling a template, ⇥ / ⇧⇥ jump between blanks instead of inserting
    /// a tab or moving focus. Each callback gets the caret's current location and
    /// returns whether it consumed the key.
    var isFillSessionActive = false
    var onFillAdvance: (Int) -> Bool = { _ in false }
    var onFillRetreat: (Int) -> Bool = { _ in false }
    var onSend: () -> Void

    /// Small gutter so text clears the caret and rounded corners without
    /// ballooning a single-line box.
    static let insets = NSSize(width: 4, height: 5)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let textView = NSTextView()
        // Force the TextKit 1 stack: TextKit 2 (the modern default) reports the
        // frame height from `usedRect`, so an empty editor would measure as tall
        // as the space SwiftUI first offers it. TextKit 1 measures the content.
        _ = textView.layoutManager
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textColor = NSColor(Rice.text)
        textView.insertionPointColor = NSColor(Rice.text)
        textView.textContainerInset = Self.insets
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Height tracks content, not the frame, so `usedRect` reflects the text.
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        context.coordinator.textView = textView

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            // The string only differs when SwiftUI drove the change (draft
            // restore, or a picked snippet) — never mid-typing, where the
            // coordinator already synced `parent.text`. Park the caret at the
            // end so the user keeps writing where the inserted text left off
            // instead of at position 0, where `setString:` would leave it.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = .systemFont(ofSize: fontSize, weight: .regular)
        scrollView.hasVerticalScroller = isScrollable
        scrollView.verticalScrollElasticity = isScrollable ? .allowed : .none
        applyPendingSelection(to: textView, context: context)
        context.coordinator.recomputeHeight()
    }

    /// Select the requested template blank once per `token`, after the text sync
    /// above so it wins over the end-of-string caret park. Clamped defensively in
    /// case the live text is shorter than the range implies.
    private func applyPendingSelection(to textView: NSTextView, context: Context) {
        guard let pending = pendingSelection,
              pending.token != context.coordinator.appliedSelectionToken else { return }
        context.coordinator.appliedSelectionToken = pending.token
        let length = (textView.string as NSString).length
        let location = min(pending.range.location, length)
        let span = min(pending.range.length, length - location)
        let range = NSRange(location: location, length: span)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: NSTextView?
        /// The last `PendingSelection.token` applied, so a re-render doesn't
        /// re-select (and steal the caret) on every `updateNSView`.
        var appliedSelectionToken = 0

        init(_ parent: GrowingTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            // Grow in the same event as the keystroke so the box never lags a
            // frame behind the text (which would flash a scroller).
            recomputeHeight(immediate: true)
        }

        /// Return-key policy. `insertNewline:` is the selector AppKit sends for
        /// every flavor of Return; the live event tells us which modifiers rode
        /// along so we can send, or fall through to a real newline.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Completion picker owns the arrow/commit/cancel keys while it's open.
            if parent.isCompletionPickerActive {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onCompletionMove(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onCompletionMove(1)
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCompletionCancel()
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if parent.onCompletionCommit() { return true }
                default:
                    break
                }
            }
            // Filling a template: ⇥ / ⇧⇥ step between blanks. The selection's
            // trailing edge is "next from here"; its leading edge is "previous
            // before here", so a blank you just typed over isn't re-selected.
            if parent.isFillSessionActive {
                let selection = textView.selectedRange()
                switch selector {
                case #selector(NSResponder.insertTab(_:)):
                    if parent.onFillAdvance(selection.location + selection.length) { return true }
                case #selector(NSResponder.insertBacktab(_:)):
                    if parent.onFillRetreat(selection.location) { return true }
                default:
                    break
                }
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if parent.sendOnReturn {
                if flags.contains(.shift) { return false }
                parent.onSend()
                return true
            } else {
                if flags.contains(.command) {
                    parent.onSend()
                    return true
                }
                return false
            }
        }

        /// Measure the text the honest way — the bounding rect of the string at
        /// the editor's width — and publish the height it needs. `usedRect` on a
        /// live NSTextView leaks the frame height for an empty buffer, so we
        /// don't trust it.
        func recomputeHeight(immediate: Bool = false) {
            guard let textView, let font = textView.font else { return }
            let lineHeight = ceil(textView.layoutManager?.defaultLineHeight(for: font)
                ?? font.pointSize * 1.2)
            let width = textView.bounds.width - GrowingTextView.insets.width * 2

            let content: CGFloat
            if textView.string.isEmpty || width <= 0 {
                content = lineHeight
            } else {
                let bounds = (textView.string as NSString).boundingRect(
                    with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                content = max(lineHeight, ceil(bounds.height))
            }
            let height = content + GrowingTextView.insets.height * 2
            let binding = parent.$measuredHeight
            guard abs(height - binding.wrappedValue) > 0.5 else { return }
            if immediate {
                // From textDidChange — a live AppKit event, safe to set now.
                binding.wrappedValue = height
            } else {
                // From updateNSView — mutating SwiftUI state mid-update is a
                // no-no, so hop to the next runloop tick.
                DispatchQueue.main.async {
                    binding.wrappedValue = height
                }
            }
        }
    }
}
