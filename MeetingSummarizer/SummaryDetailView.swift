import SwiftUI

struct SummaryDetailView: View {
    let summary: String
    @Environment(\.dismiss) var dismiss
    @State private var showShareSheet = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(summary)
                    .font(.body)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Meeting Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = summary
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [summary])
            }
        }
    }
}

// UIActivityViewController wrapper for sharing
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SummaryDetailView(summary: "This is a sample meeting summary with multiple lines of text to demonstrate how the view looks with actual content.")
}
