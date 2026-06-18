import SwiftUI
import UniformTypeIdentifiers

/// Drag-to-rearrange for the highlight bubble row. As a long-press-dragged bubble
/// passes over another it reorders the live `items` list, persisting the new order
/// on drop. A *pinned* bubble (the Instagram profile) is never displaced, so it
/// stays first.
struct BubbleDropDelegate: DropDelegate {
    let item: Entry
    @Binding var items: [Entry]
    @Binding var dragging: Entry?
    let isPinned: (URL) -> Bool
    let onReorder: ([Entry]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item, !isPinned(item.url),
              let from = items.firstIndex(of: dragging),
              let to = items.firstIndex(of: item) else { return }
        if items[to] != dragging {
            withAnimation { items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onReorder(items)
        return true
    }
}
