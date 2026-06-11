import SwiftUI

/// Sets (or clears) a folder's birthday. Files in the folder and its subfolders
/// then show an "Age" computed from this date and their EXIF capture date.
struct BirthdayEditorView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    @State private var date: Date
    private let hadExisting: Bool

    init(folder: URL, existing: Date?) {
        self.folder = folder
        self.hadExisting = existing != nil
        let fallback = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
        _date = State(initialValue: existing ?? fallback)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Birthday", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                } footer: {
                    Text("Photos and videos in “\(folder.lastPathComponent)” and its subfolders will show an Age based on this date and each item's capture date.")
                }
                if hadExisting {
                    Section {
                        Button("Remove Birthday", role: .destructive) {
                            library.setBirthday(nil, for: folder)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Folder Birthday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { library.setBirthday(date, for: folder); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
