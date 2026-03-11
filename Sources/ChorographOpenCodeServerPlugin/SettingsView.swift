// SettingsView.swift — OpenCode Server settings panel

import SwiftUI
import ChorographPluginSDK

struct OpenCodeServerSettingsView: View {
    @AppStorage("opencodeServerURL")       private var serverURL       = "http://localhost:4096"
    @AppStorage("opencodeServerDirectory") private var serverDirectory = ""
    @AppStorage("opencodeModel")           private var selectedModelKey = ""
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var availableModels: [ProviderModel] = []
    @State private var isLoadingModels = false

    private let provider = OpenCodeServerProvider()

    enum ConnectionStatus {
        case unknown, checking, connected(String), failed(String)
        var isChecking: Bool { if case .checking = self { return true }; return false }
        var label: String {
            switch self {
            case .unknown:            return "Not checked"
            case .checking:           return "Checking…"
            case .connected(let v):   return "Connected — v\(v)"
            case .failed(let reason): return reason
            }
        }
        var color: Color {
            switch self {
            case .unknown, .checking: return .secondary
            case .connected:          return .green
            case .failed:             return .red
            }
        }
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Server URL", text: $serverURL)
                    .onSubmit { Task { await checkHealth() } }

                TextField("Project directory (leave blank for cwd)", text: $serverDirectory)

                HStack {
                    Button("Check Connection") { Task { await checkHealth() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionStatus.isChecking)

                    if connectionStatus.isChecking { ProgressView().scaleEffect(0.7) }

                    Text(connectionStatus.label)
                        .font(.caption)
                        .foregroundStyle(connectionStatus.color)
                }
            }

            Section("Model") {
                if isLoadingModels {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if availableModels.isEmpty {
                    Text("No models available — connect to server first.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $selectedModelKey) {
                        Text("Server default").tag("")
                        ForEach(availableModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .onChange(of: selectedModelKey) { newValue in
                        Task { await provider.setSelectedModel(newValue.isEmpty ? nil : newValue) }
                    }
                }
            }

            Section("Info") {
                Text("Run `opencode serve` in your project directory, then enter the URL above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await checkHealth() }
        .task { await loadModels() }
    }

    private func checkHealth() async {
        connectionStatus = .checking
        let health = await provider.health()
        if health.isReachable {
            connectionStatus = .connected(health.version ?? "")
        } else {
            connectionStatus = .failed(health.detail ?? "Unreachable")
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        do {
            availableModels = try await provider.availableModels()
        } catch {
            availableModels = []
        }
        isLoadingModels = false
    }
}
