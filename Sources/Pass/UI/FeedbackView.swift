import SwiftUI

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = FeedbackKind.request
    @State private var title = ""
    @State private var message = ""
    @State private var email = ""
    @State private var state = SubmissionState.editing
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case message
        case email
    }

    private enum SubmissionState: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state != .sending
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state == .sent {
                confirmation
            } else {
                form
            }
        }
        .frame(width: 520, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = .title }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("Request / feedback")
                    .font(.system(size: 15, weight: .semibold))
                Text("Send a signal straight to the Pass team")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 15) {
            Picker("Type", selection: $kind) {
                ForEach(FeedbackKind.allCases) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)

            field("Title", hint: "A short summary") {
                TextField("What should we know?", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
            }

            field("Details", hint: "What happened, or what would make Pass better?") {
                TextEditor(text: $message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(.separator.opacity(0.8))
                    }
                    .focused($focusedField, equals: .message)
                    .frame(minHeight: 145)
            }

            field("Email", hint: "Optional — only if you'd like a reply") {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .email)
            }

            if case .failed(let error) = state {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
            HStack {
                Text("Stored privately in the Pass team's Notion workspace.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    if state == .sending {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 64)
                    } else {
                        Text("Send signal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }

    private var confirmation: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(.orange, in: Circle())
            Text("Signal received")
                .font(.system(size: 21, weight: .semibold))
            Text("Thanks — your note is now in the team's feedback queue.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func field<Content: View>(
        _ label: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12, weight: .semibold))
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            content()
        }
    }

    private func submit() {
        state = .sending
        Task {
            do {
                try await FeedbackService.submit(
                    type: kind,
                    title: title,
                    message: message,
                    email: email
                )
                state = .sent
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct FeedbackButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Request / feedback", systemImage: "dot.radiowaves.left.and.right")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Send a request, bug report, or feedback")
        .sheet(isPresented: $isPresented) {
            FeedbackView()
        }
    }
}
