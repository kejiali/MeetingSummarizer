import SwiftUI
import UniformTypeIdentifiers
import MediaPlayer
import AVFoundation

struct AudioFilePicker: UIViewControllerRepresentable {
    let onFilePicked: (URL) -> Void
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIViewController {
        let hostingController = UIHostingController(rootView: AudioPickerMenu(onFilePicked: onFilePicked))
        return hostingController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct AudioPickerMenu: View {
    let onFilePicked: (URL) -> Void
    @State private var showDocumentPicker = false
    @State private var showMediaPicker = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showMediaPicker = true
                    } label: {
                        Label("Voice Memos & Music Library", systemImage: "music.note.list")
                    }
                    
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("Files & Downloads", systemImage: "folder")
                    }
                }
            }
            .navigationTitle("Select Audio Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPickerView(onFilePicked: onFilePicked)
            }
            .sheet(isPresented: $showMediaPicker) {
                MediaPickerView(onFilePicked: onFilePicked)
            }
        }
    }
}

struct DocumentPickerView: UIViewControllerRepresentable {
    let onFilePicked: (URL) -> Void
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [
                UTType.audio,
                UTType.mpeg4Audio,
                UTType(filenameExtension: "m4a")!
            ],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView
        
        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            
            do {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
                parent.onFilePicked(tempURL)
            } catch {
                print("Error copying file: \(error)")
            }
        }
    }
}

struct MediaPickerView: UIViewControllerRepresentable {
    let onFilePicked: (URL) -> Void
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = false
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let parent: MediaPickerView
        
        init(_ parent: MediaPickerView) {
            self.parent = parent
        }
        
        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            mediaPicker.dismiss(animated: true)
            
            guard let item = mediaItemCollection.items.first,
                  let assetURL = item.value(forProperty: MPMediaItemPropertyAssetURL) as? URL else {
                print("Could not get audio file URL")
                return
            }
            
            // Export the audio file to a temporary location
            Task {
                do {
                    let asset = AVURLAsset(url: assetURL)
                    
                    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                        print("Could not create export session")
                        return
                    }
                    
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("m4a")
                    
                    exportSession.outputURL = tempURL
                    exportSession.outputFileType = .m4a
                    
                    await exportSession.export()
                    
                    guard exportSession.status == .completed else {
                        if let error = exportSession.error {
                            print("Export failed: \(error.localizedDescription)")
                        }
                        return
                    }
                    
                    await MainActor.run {
                        self.parent.onFilePicked(tempURL)
                    }
                } catch {
                    print("Export failed: \(error.localizedDescription)")
                }
            }
        }
        
        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            mediaPicker.dismiss(animated: true)
        }
    }
}
