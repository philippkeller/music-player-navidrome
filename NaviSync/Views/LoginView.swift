import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var server = "https://music.backl.io"
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $server)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .textContentType(.URL)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(connect)
                } header: {
                    Text("Navidrome Server")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            if isConnecting {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isConnecting || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("NaviSync")
        }
        #if os(macOS)
        .frame(maxWidth: 480, maxHeight: 360)
        .padding()
        #endif
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        error = nil
        Task {
            do {
                try await model.login(server: server, username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
