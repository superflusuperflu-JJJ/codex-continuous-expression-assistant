import AppKit
import SwiftUI

/// Keep native editing state local; a model echo must never rewrite text storage.
struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text:$text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = context.coordinator.makeTextView()
        context.coordinator.synchronize(text,in:scroll.documentView as! NSTextView)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.synchronize(text,in:view)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var publishingEdit = false
        init(text: Binding<String>) { self.text = text }
        func makeTextView() -> NSTextView {
            let view = NSTextView(frame:NSRect(x:0,y:0,width:400,height:100))
            view.isRichText = false
            view.isEditable = true; view.isSelectable = true
            view.allowsUndo = true
            view.font = .systemFont(ofSize:13)
            view.textColor = .textColor
            view.drawsBackground = false
            view.isVerticallyResizable = true; view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.textContainer?.containerSize = NSSize(width:400,height:CGFloat.greatestFiniteMagnitude)
            view.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
            view.delegate = self
            view.setAccessibilityLabel("最终 Prompt")
            return view
        }
        func synchronize(_ value: String, in view: NSTextView) {
            guard !publishingEdit, !view.hasMarkedText(), !view.string.utf8.elementsEqual(value.utf8) else { return }
            let selection = view.selectedRanges
            let origin = view.enclosingScrollView?.contentView.bounds.origin
            view.string = value
            let length = (value as NSString).length
            view.selectedRanges = selection.map { item in
                let range = item.rangeValue
                let start = min(range.location,length)
                return NSValue(range:NSRange(location:start,length:min(range.length,length-start)))
            }
            if let origin, let scroll = view.enclosingScrollView {
                scroll.contentView.scroll(to:origin); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            publishingEdit = true
            defer { publishingEdit = false }
            text.wrappedValue = view.string
        }
    }
}
