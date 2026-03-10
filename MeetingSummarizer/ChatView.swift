import SwiftUI

struct ChatView: View {
    let transcript: String
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading = false
    @Environment(\.dismiss) var dismiss
    
    private let bedrock = BedrockService(
        region: Config.awsRegion,
        modelId: Config.bedrockModel,
        accessKey: Config.awsAccessKey,
        secretKey: Config.awsSecretKey
    )
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            
                            if isLoading {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Thinking...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let lastMessage = messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                // Input area
                HStack(spacing: 12) {
                    TextField("Ask a question about the transcript...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(inputText.isEmpty ? .gray : .blue)
                    }
                    .disabled(inputText.isEmpty || isLoading)
                }
                .padding()
            }
            .navigationTitle("Chat with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                addSystemMessage("I have access to your meeting transcript and can answer questions about it. I can also help with general questions!")
            }
        }
    }
    
    private func addSystemMessage(_ text: String) {
        messages.append(ChatMessage(text: text, isUser: false, isSystem: true))
    }
    
    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        
        let userMessage = inputText
        messages.append(ChatMessage(text: userMessage, isUser: true))
        inputText = ""
        
        Task {
            await getAIResponse(for: userMessage)
        }
    }
    
    private func getAIResponse(for question: String) async {
        isLoading = true
        
        do {
            let response = try await bedrock.chat(transcript: transcript, question: question)
            messages.append(ChatMessage(text: response, isUser: false))
        } catch {
            messages.append(ChatMessage(text: "Sorry, I encountered an error: \(error.localizedDescription)", isUser: false))
        }
        
        isLoading = false
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showCopyButton = false
    
    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if !message.isUser && showCopyButton {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        .transition(.scale)
                    }
                    
                    Text(message.text)
                        .padding(12)
                        .background(message.isSystem ? Color.orange.opacity(0.1) : 
                                   message.isUser ? Color.blue : Color(.systemGray5))
                        .foregroundStyle(message.isUser ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .textSelection(.enabled)
                        .onLongPressGesture(minimumDuration: 0.1) {
                            if !message.isUser {
                                withAnimation {
                                    showCopyButton.toggle()
                                }
                            }
                        }
                }
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            if !message.isUser { Spacer() }
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let isSystem: Bool
    let timestamp: Date
    
    init(text: String, isUser: Bool, isSystem: Bool = false) {
        self.text = text
        self.isUser = isUser
        self.isSystem = isSystem
        self.timestamp = Date()
    }
}

#Preview {
    ChatView(transcript: "This is a sample meeting transcript about project planning.")
}
