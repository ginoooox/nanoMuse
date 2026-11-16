import Foundation

extension ProviderInstance {
    /// API-key OpenAI-compatible endpoints only; vendor OAuth keeps its own headers.
    var supportsCustomHeaders: Bool {
        credentialType == .apiKey && (providerType == .openAI || providerType == .openAIResponses)
            && NanoMuseProviderHeaderRules.origin(effectiveCustomBaseURL) != nil
    }

    var effectiveCustomHeaders: [String: String] {
        guard supportsCustomHeaders else { return [:] }
        return NanoMuseProviderHeaders.values(instanceId: id, baseURL: effectiveCustomBaseURL)
    }
}
