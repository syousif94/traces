import Foundation
import Observation

/// App-wide model settings. Per-project provider/model live in `.traceworks/settings.json`; the API
/// key is in the Keychain.
@Observable @MainActor
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var openAIBaseURL: String { didSet { d.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    var openAIModel: String { didSet { d.set(openAIModel, forKey: "openAIModel") } }
    var anthropicModel: String { didSet { d.set(anthropicModel, forKey: "anthropicModel") } }
    var effort: String { didSet { d.set(effort, forKey: "effort") } }
    var openAIVision: Bool { didSet { d.set(openAIVision, forKey: "openAIVision") } }
    var anthropicKey: String { didSet { Keychain.set(anthropicKey, for: "anthropic") } }
    var openAIKey: String { didSet { Keychain.set(openAIKey, for: "openai") } }
    var mcpEnabled: Bool { didSet { d.set(mcpEnabled, forKey: "mcpEnabled") } }
    /// DigiKey Product Information API (v4) credentials, for parts search.
    var digikeyClientId: String { didSet { Keychain.set(digikeyClientId, for: "digikeyClientId") } }
    var digikeyClientSecret: String { didSet { Keychain.set(digikeyClientSecret, for: "digikeyClientSecret") } }

    private init() {
        openAIBaseURL = d.string(forKey: "openAIBaseURL") ?? "http://localhost:1234"
        openAIModel = d.string(forKey: "openAIModel") ?? "local-model"
        anthropicModel = d.string(forKey: "anthropicModel") ?? "claude-opus-5-5"
        effort = d.string(forKey: "effort") ?? "high"
        openAIVision = d.object(forKey: "openAIVision") as? Bool ?? false
        anthropicKey = Keychain.get("anthropic") ?? ""
        openAIKey = Keychain.get("openai") ?? ""
        mcpEnabled = d.object(forKey: "mcpEnabled") as? Bool ?? true
        digikeyClientId = Keychain.get("digikeyClientId") ?? ""
        digikeyClientSecret = Keychain.get("digikeyClientSecret") ?? ""
    }

    func modelConfig(provider: String) -> ModelConfig {
        if provider == "openai" {
            return ModelConfig(provider: "openai", baseUrl: openAIBaseURL, model: openAIModel, apiKey: openAIKey, vision: openAIVision, effort: "")
        }
        return ModelConfig(provider: "anthropic", baseUrl: "https://api.anthropic.com", model: anthropicModel, apiKey: anthropicKey, vision: true, effort: effort)
    }

    func label(provider: String) -> String {
        provider == "openai" ? "\(openAIModel) · local" : "Claude · BYO key"
    }
}
