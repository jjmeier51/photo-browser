import SwiftUI
import UIKit
import WebKit

/// The resolver's Cloudflare check, shown to the person when the hidden browser couldn't pass it
/// (see `TikTokWebFetcher`): the very same web view, now visible and tappable, on the page that is
/// asking. The moment the page turns into the resolver's JSON the check is passed — the clearance
/// cookie is banked for the plain requests, the sheet reports back and the caller runs the download
/// again. Cancelling just closes it; the web view goes back behind the app either way.
struct TikTokChallengeSheet: View {
    let onCleared: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("tikwm.com, the service that lists a TikTok profile's videos, is checking that a person is asking. If it shows a box, tap Verify. As soon as it's happy, this closes and the download carries on by itself.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 10)
                Divider()
                TikTokChallengeWebView(onCleared: onCleared)
            }
            .navigationTitle("One quick check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Hosts `TikTokWebFetcher`'s web view while the sheet is up and polls it for the JSON that means
/// the check is passed.
private struct TikTokChallengeWebView: UIViewRepresentable {
    let onCleared: () -> Void

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .systemBackground
        TikTokWebFetcher.shared.present(in: host)
        context.coordinator.start(onCleared)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
        TikTokWebFetcher.shared.retire()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var poll: Task<Void, Never>?

        func start(_ onCleared: @escaping () -> Void) {
            poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard self != nil, !Task.isCancelled else { return }
                    if await TikTokWebFetcher.shared.cleared() {
                        onCleared()
                        return
                    }
                }
            }
        }

        func stop() {
            poll?.cancel()
            poll = nil
        }
    }
}
