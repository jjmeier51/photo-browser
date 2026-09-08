import SwiftUI

/// "Create AI Tune": train a new Astria fine-tune (a Flux LoRA) from photos in the current folder,
/// so it can later be picked in Edit / Create with AI. The user selects training images (4–20 works
/// best), a subject class ("woman", "man", "style", …) and a name; training runs app-wide (a
/// progress pill) and the tune appears in the pickers when it's done.
struct CreateTuneView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    let candidates: [URL]        // image URLs in the current folder

    @State private var selected: Set<URL> = []
    @State private var subject = "woman"
    @State private var title = ""
    @State private var token = "ohwx"
    @State private var baseModel: TuneBaseModel = .flux
    @State private var showAdvanced = false

    private let subjects = ["woman", "man", "person", "couple", "style", "object", "animal"]
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 6)]

    private var canCreate: Bool {
        selected.count >= 4 && !subject.trimmingCharacters(in: .whitespaces).isEmpty && !library.creatingTune
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Base model", selection: $baseModel) {
                        ForEach(TuneBaseModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Subject", selection: $subject) {
                        ForEach(subjects, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("Name (e.g. \(folder.lastPathComponent))", text: $title)
                } header: {
                    Text("What are you training?")
                } footer: {
                    Text("\(baseModel.note) “Subject” is the class the model learns (a person → woman/man/person; a look → style). The name is just for you.")
                }

                if baseModel.usesToken {
                    Section {
                        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                            HStack {
                                Text("Subject word")
                                Spacer()
                                TextField("ohwx", text: $token)
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .frame(width: 120)
                            }
                        }
                    } footer: {
                        Text("The unique word used to summon this subject in prompts. The default is fine.")
                    }
                } else {
                    Section {
                        Text("This base trains a FaceID model — it recognizes the face directly, so there's no subject word to set.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if candidates.isEmpty {
                        Text("No photos in this folder to train from.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(candidates, id: \.self) { url in
                                TuneThumb(url: url, selected: selected.contains(url))
                                    .onTapGesture {
                                        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
                                    }
                            }
                        }
                    }
                } header: {
                    Text("Training photos — \(selected.count) selected")
                } footer: {
                    Text("Pick 4–20 clear photos of the same subject (varied angles/lighting, one subject per photo). Training uploads them to Astria and takes several minutes; you can keep using the app.")
                }
            }
            .navigationTitle("Create AI Tune")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Train") { create() }.disabled(!canCreate)
                }
            }
            .onAppear { if title.isEmpty { title = folder.lastPathComponent } }
        }
    }

    private func create() {
        guard AIExtend.isConfigured else { return }
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? folder.lastPathComponent : title
        // Keep a stable selection order (grid order) for the upload.
        let urls = candidates.filter { selected.contains($0) }
        library.startCreateTune(title: name, subject: subject,
                                token: baseModel.usesToken ? token.trimmingCharacters(in: .whitespaces) : "",
                                branch: baseModel.branch, baseTuneID: baseModel.baseTuneID,
                                modelType: baseModel.modelType, imageURLs: urls)
        dismiss()
    }
}

/// A small selectable thumbnail for the training-image grid.
private struct TuneThumb: View {
    let url: URL
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .task(id: url) {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let entry = Entry(url: url, name: url.lastPathComponent, kind: .image,
                              size: Int64(vals?.fileSize ?? 0), modified: vals?.contentModificationDate ?? Date())
            image = await Thumbnailer.shared.thumbnail(for: entry, size: CGSize(width: 84, height: 84), scale: 2)
        }
    }
}
