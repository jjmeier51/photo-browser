import SwiftUI
import UIKit

/// The prompt-helper sections shared by Edit with AI and Create with AI, so both screens look and
/// behave the same: a fine-print prompting reminder, the Reusable Prompts list, and the prompt
/// history with hearts. Each takes a binding to the screen's prompt field.

/// A very small reminder of how to structure a prompt, in fine text right under the prompt box.
struct PromptingReminderSection: View {
    static let text = "Order: subject → wardrobe → scene → framing (crop and camera position) → camera details (natural sensor noise, slight handheld imperfections, subtle HDR). Add imperfection keywords; ban beauty filters for realistic, non-plasticky skin."

    var body: some View {
        Section {
            Label {
                Text(Self.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lightbulb")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
        }
    }
}

/// The compact Use / Copy pair under a prompt: two small capsules, centred. Explicit plain-style
/// buttons with their own padding, so a Form row can't inflate one of them into a tall, off-centre
/// block the way the stock bordered styles did.
struct PromptActionButtons: View {
    let prompt: String
    let onUse: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onUse) {
                Label("Use", systemImage: "text.insert")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button { UIPasteboard.general.string = prompt } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Always-available saved prompts (`AIExtend.reusablePrompts`): one-tap Use (fills the prompt) or Copy.
struct ReusablePromptsSection: View {
    @Binding var prompt: String

    var body: some View {
        Section {
            ForEach(AIExtend.reusablePrompts, id: \.self) { p in
                VStack(alignment: .leading, spacing: 8) {
                    Text(p).font(.callout)
                    PromptActionButtons(prompt: p) { prompt = p }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Reusable Prompts")
        } footer: {
            Text("Tap Use to drop one into the prompt above, or Copy it.")
        }
    }
}

/// Past prompts, newest first, with a heart on each. **All** shows the history; **Favorites** shows
/// just the hearted ones, so a prompt worth keeping is one tap away however long ago it ran.
/// Hearted prompts are never pushed out by the history cap (`Library.recordAIPrompt`).
struct PromptHistorySection: View {
    @Environment(Library.self) private var library
    @Binding var prompt: String
    @State private var favoritesOnly = false

    private var shown: [String] {
        favoritesOnly ? library.aiPromptHistory.filter { library.isFavoriteAIPrompt($0) } : library.aiPromptHistory
    }

    var body: some View {
        Section {
            Picker("Show", selection: $favoritesOnly) {
                Text("All (\(library.aiPromptHistory.count))").tag(false)
                Label("Favorites (\(library.favoriteAIPrompts.count))", systemImage: "heart.fill").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if shown.isEmpty {
                Text("No favorite prompts yet — tap the heart on a prompt to keep it here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shown, id: \.self) { past in
                            let hearted = library.isFavoriteAIPrompt(past)
                            HStack(spacing: 8) {
                                Button { prompt = past } label: {
                                    HStack {
                                        Text(past).lineLimit(2).foregroundStyle(.primary)
                                        Spacer(minLength: 4)
                                        Image(systemName: "arrow.up.circle").font(.callout).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button { library.toggleFavoriteAIPrompt(past) } label: {
                                    Image(systemName: hearted ? "heart.fill" : "heart")
                                        .font(.callout)
                                        .foregroundStyle(hearted ? Color.red : Color.secondary)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(hearted ? "Unfavorite prompt" : "Favorite prompt")
                            }
                            .padding(.vertical, 8)
                            .contextMenu {
                                Button { prompt = past } label: { Label("Use as Prompt", systemImage: "text.insert") }
                                Button { UIPasteboard.general.string = past } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { library.toggleFavoriteAIPrompt(past) } label: {
                                    Label(hearted ? "Unfavorite" : "Favorite", systemImage: hearted ? "heart.slash" : "heart")
                                }
                                Button(role: .destructive) { library.deleteAIPrompt(past) } label: {
                                    Label("Remove from History", systemImage: "trash")
                                }
                            }
                            if past != shown.last { Divider() }
                        }
                    }
                }
                .frame(height: min(CGFloat(shown.count) * 52, 220))
            }
        } header: {
            Text("Previous prompts")
        } footer: {
            Text("Tap a prompt to use it again; tap ♥ to keep it in Favorites. Long-press to copy or remove it.")
        }
    }
}
