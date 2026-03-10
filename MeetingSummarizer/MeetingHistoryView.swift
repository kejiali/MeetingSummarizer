import SwiftUI
import CoreData

struct MeetingHistoryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Meeting.date, ascending: false)],
        animation: .default)
    private var meetings: FetchedResults<Meeting>
    
    @Binding var selectedMeeting: Meeting?
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(meetings) { meeting in
                    Button {
                        selectedMeeting = meeting
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.date ?? Date(), style: .date)
                                .font(.headline)
                            Text(meeting.date ?? Date(), style: .time)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            if let transcript = meeting.transcript, !transcript.isEmpty {
                                Text(transcript.prefix(100) + "...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            
                            if meeting.summary != nil {
                                Label("Summarized", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: deleteMeetings)
            }
            .navigationTitle("Meeting History")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func deleteMeetings(offsets: IndexSet) {
        withAnimation {
            offsets.map { meetings[$0] }.forEach(viewContext.delete)
            try? viewContext.save()
        }
    }
}
