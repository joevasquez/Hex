import HexCore
import SwiftUI

struct TodoistTokenSheetIOS: View {
  @Environment(\.dismiss) private var dismiss

  @State private var token: String = ""
  @State private var isValidating = false
  @State private var errorMessage: String?
  @State private var hasExistingToken = false

  let onConnected: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("Paste API token", text: $token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { validateAndSave() }
        } header: {
          Label("Todoist API Token", systemImage: "key")
        } footer: {
          Text("Get your token at todoist.com → Settings → Integrations → Developer.")
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .font(.caption)
          }
        }

        if hasExistingToken {
          Section {
            Button("Disconnect", role: .destructive) {
              disconnect()
            }
          }
        }
      }
      .navigationTitle("Connect Todoist")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            validateAndSave()
          } label: {
            if isValidating {
              ProgressView().controlSize(.small)
            } else {
              Text("Connect")
            }
          }
          .disabled(token.isEmpty || isValidating)
        }
      }
      .onAppear {
        let (existing, _) = KeychainStore.read(account: KeychainKey.todoistAPIToken)
        hasExistingToken = existing != nil && !existing!.isEmpty
      }
    }
  }

  private func validateAndSave() {
    guard !token.isEmpty else { return }
    isValidating = true
    errorMessage = nil

    Task {
      let result = await IOSTodoistAdapter.validateToken(token)
      if result.isValid {
        KeychainStore.save(account: KeychainKey.todoistAPIToken, value: token)
        onConnected()
        dismiss()
      } else {
        errorMessage = "That token didn't work. Double-check it and try again."
      }
      isValidating = false
    }
  }

  private func disconnect() {
    KeychainStore.delete(account: KeychainKey.todoistAPIToken)
    dismiss()
  }
}
