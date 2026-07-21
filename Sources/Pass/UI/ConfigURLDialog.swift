import AppKit
import SwiftUI

struct ConfigURLAddButton: View {
    let session: Session

    @Environment(AppModel.self) private var appModel
    @State private var show = false
    @State private var rawURL = ""
    @State private var label = ""
    @State private var error: String?
    @FocusState private var urlFocused: Bool

    var body: some View {
        Button {
            rawURL = ""
            label = ""
            error = nil
            show = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help("Add URL")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add URL")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("localhost:3000 · admin.example.com", text: $rawURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($urlFocused)
                    .onSubmit { add() }
                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { add() }
                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { show = false }
                        .controlSize(.small)
                    Button("Add") { add() }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 280)
            .onAppear {
                DispatchQueue.main.async {
                    urlFocused = true
                    FieldEditorFix.cursorToEnd()
                }
            }
        }
    }

    private func add() {
        do {
            try appModel.addConfiguredURL(
                projectRoot: session.projectRoot,
                rawURL: rawURL,
                label: label
            )
            show = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
enum ConfigURLDialog {
    static func addURL(for session: Session, appModel: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add URL"
        let projectName = URL(fileURLWithPath: session.projectRoot).lastPathComponent
        alert.informativeText = "Saved to \(PassConfigStore.fileName) in \(projectName)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let urlField = NSTextField(frame: .zero)
        urlField.placeholderString = "localhost:3000 · admin.example.com"
        let labelField = NSTextField(frame: .zero)
        labelField.placeholderString = "Label (optional)"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(labeledField("URL", urlField))
        stack.addArrangedSubview(labeledField("Label", labelField))
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = urlField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try appModel.addConfiguredURL(
                projectRoot: session.projectRoot,
                rawURL: urlField.stringValue,
                label: labelField.stringValue
            )
        } catch {
            showError(error)
        }
    }

    private static func labeledField(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return stack
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not add URL"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
