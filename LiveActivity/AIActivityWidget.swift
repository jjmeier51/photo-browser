// This file belongs to the **Widget Extension** target, NOT the app target.
// See LiveActivity/README.md for the (quick) setup. It is intentionally kept
// outside PhotoBrowser/ so the app's synchronized file group doesn't compile it
// (a second @main would clash with PhotoBrowserApp).

import WidgetKit
import SwiftUI
import ActivityKit

/// The Live Activity (Dynamic Island + Lock Screen) for a running AI image task.
/// Shows "AI In Progress" with a spinner while Astria works, then a check (Ready)
/// or warning (Failed) when it finishes.
@main
struct AIActivityWidgetBundle: WidgetBundle {
    var body: some Widget { AIActivityWidget() }
}

struct AIActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AIActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 12) {
                statusIcon(context).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title).font(.headline)
                    Text(subtitle(context)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !context.state.done { ProgressView().tint(.purple) }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "sparkles").foregroundStyle(.purple).font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.done { statusIcon(context) }
                    else { ProgressView().tint(.purple) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.title).font(.caption.weight(.semibold))
                        Text(context.state.phase).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(.purple)
            } compactTrailing: {
                if context.state.done { statusGlyph(context) }
                else { ProgressView().tint(.purple).scaleEffect(0.7) }
            } minimal: {
                if context.state.done { statusGlyph(context) }
                else { Image(systemName: "sparkles").foregroundStyle(.purple) }
            }
            .keylineTint(.purple)
        }
    }

    private func subtitle(_ context: ActivityViewContext<AIActivityAttributes>) -> String {
        context.state.detail.isEmpty ? context.state.phase : "\(context.state.phase) · \(context.state.detail)"
    }
    @ViewBuilder private func statusIcon(_ context: ActivityViewContext<AIActivityAttributes>) -> some View {
        if !context.state.done { Image(systemName: "sparkles").foregroundStyle(.purple) }
        else if context.state.phase == "Ready" { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
    }
    @ViewBuilder private func statusGlyph(_ context: ActivityViewContext<AIActivityAttributes>) -> some View {
        if context.state.phase == "Ready" { Image(systemName: "checkmark").foregroundStyle(.green) }
        else { Image(systemName: "exclamationmark").foregroundStyle(.orange) }
    }
}
