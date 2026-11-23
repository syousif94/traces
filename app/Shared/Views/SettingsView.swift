import SwiftUI

struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    var doc: DocumentModel?
    @State private var networkTools = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Anthropic API key", text: $settings.anthropicKey)
                        .textContentType(.password)
                    TextField("Model", text: $settings.anthropicModel)
                    Picker("Effort", selection: $settings.effort) {
                        ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                    }
                } header: { Text("Claude (Anthropic API)") } footer: {
                    Text("The key is stored in the Keychain and sent only to api.anthropic.com. Requests opt in to server-side fallbacks, so a refused turn can be retried on a fallback model.")
                }
                Section {
                    TextField("Base URL", text: $settings.openAIBaseURL)
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        #endif
                    TextField("Model", text: $settings.openAIModel)
                    SecureField("API key (optional)", text: $settings.openAIKey)
                    Toggle("Model can read images", isOn: $settings.openAIVision)
                } header: { Text("OpenAI-compatible (LM Studio, Ollama…)") } footer: {
                    Text("LM Studio's default server is http://localhost:1234/v1. From an iPhone or iPad, use your Mac's LAN address.")
                }
                Section {
                    TextField("Client ID", text: $settings.digikeyClientId)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    SecureField("Client secret", text: $settings.digikeyClientSecret)
                } header: { Text("DigiKey") } footer: {
                    Text("For DigiKey search in Add a part. Create an app at developer.digikey.com with the Product Information V4 API and paste its credentials here. They're kept in the Keychain and sent only to api.digikey.com. JLCPCB search needs no key.")
                }
                if let doc {
                    Section {
                        Toggle("Network tools (parts and registry search)", isOn: $networkTools)
                            .onChange(of: networkTools) { _, v in
                                var s = doc.project.settings(); s.networkTools = v
                                try? doc.project.saveSettings(settings: s)
                            }
                    } header: { Text("This project") }
                }
                #if os(macOS)
                Section {
                    Toggle("Run MCP server", isOn: $settings.mcpEnabled)
                        .onChange(of: settings.mcpEnabled) { _, on in if on { MCPServer.shared.start() } else { MCPServer.shared.stop() } }
                    if settings.mcpEnabled {
                        Text(MCPServer.shared.helperCommand).font(Theme.mono(12)).textSelection(.enabled)
                    }
                } header: { Text("MCP") } footer: {
                    Text("Lets Claude Code or Claude Desktop drive the open project with the same tools as the built-in agent. Add the command above as a stdio MCP server.")
                }
                #endif
                Section {
                    LabeledContent("tscircuit engine", value: EngineBridge.shared.version)
                    LabeledContent("Core", value: coreVersion())
                } header: { Text("About") } footer: {
                    Text("Traceworks is an independent app built on the open-source tscircuit packages (MIT). It is not an official tscircuit product.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if let doc { networkTools = doc.project.settings().networkTools } }
        }
        .frame(minWidth: 480, minHeight: 560)
    }
}
