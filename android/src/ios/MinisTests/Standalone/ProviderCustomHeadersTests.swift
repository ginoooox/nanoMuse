import Foundation

/// Compile with the shipping Rules and Keychain files, without the iOS test host.
@main
enum ProviderCustomHeadersTests {
    static func main() throws {
        typealias Rules = NanoMuseProviderHeaderRules
        func rejects(_ rows: [Rules.Header]) {
            do {
                _ = try Rules.validated(rows)
                fatalError("Accepted invalid headers")
            } catch Rules.Failure.invalidHeader {} catch { fatalError("Unexpected failure") }
        }

        let rows = try Rules.validated([
            .init(name: " CF-Access-Client-Id ", value: " fixture-id "),
            .init(name: "CF-Access-Client-Secret", value: "fixture-secret"),
            .init(name: "User-Agent", value: "FixtureClient/1.0"),
            .init(name: "x-codex-client-version", value: "1.0"),
            .init(),
        ])
        precondition(rows.count == 4 && rows[0].name == "CF-Access-Client-Id")
        precondition(rows[0].value == "fixture-id")
        for name in ["Host", "AUTHORIZATION", "api-key", "Content-Type", "Content-Length", "Bad Name", "Bad:Name", "非ASCII"] {
            rejects([.init(name: name, value: "fixture")])
        }
        rejects([.init(name: "X-Fixture", value: "value\r\nAuthorization: injected")])
        rejects([.init(name: "X-Fixture\n", value: "fixture")])
        rejects([.init(name: "X-Fixture", value: "\u{0}")])
        rejects([.init(name: "X-Fixture", value: "")])
        rejects([.init(name: "X-Fixture", value: "1"), .init(name: "x-fixture", value: "2")])
        let merged = Rules.merging(["user-agent": "custom", "X-Fixture": "secret"], into: ["User-Agent": "default", "X-Cloud-Device": "keep"])
        precondition(merged["User-Agent"] == nil && merged["user-agent"] == "custom")
        precondition(merged["X-Cloud-Device"] == "keep")
        precondition(Rules.redacted(merged).values.allSatisfy { $0 == "***" })
        precondition(Rules.origin("https://EXAMPLE.invalid/v1") == Rules.origin("https://example.invalid:443/other"))
        precondition(Rules.origin("https://example.invalid") != Rules.origin("http://example.invalid"))
        precondition(Rules.origin("https://example.invalid:444") != Rules.origin("https://example.invalid"))
        precondition(Rules.origin("https://user:pass@example.invalid") == nil)
        precondition(Rules.origin("example.invalid") == nil)

        // Use a unique service and fake values; exercise actual Keychain persistence.
        let instance = "headers-test-\(UUID().uuidString)"
        defer { NanoMuseProviderHeaders.remove(instanceId: instance) }
        try NanoMuseProviderHeaders.save(rows, instanceId: instance, baseURL: "https://example.invalid/v1")
        precondition(NanoMuseProviderHeaders.load(instanceId: instance, baseURL: "https://example.invalid/other") == rows)
        precondition(NanoMuseProviderHeaders.load(instanceId: instance, baseURL: "https://other.invalid/v1").isEmpty)
        precondition(NanoMuseProviderHeaders.load(instanceId: instance, baseURL: "http://example.invalid/v1").isEmpty)
        precondition(NanoMuseProviderHeaders.load(instanceId: "another-\(instance)", baseURL: "https://example.invalid/v1").isEmpty)
        let replacement = [Rules.Header(name: "X-Fixture", value: "replacement")]
        try NanoMuseProviderHeaders.save(replacement, instanceId: instance, baseURL: "https://example.invalid/v1")
        precondition(NanoMuseProviderHeaders.load(instanceId: instance, baseURL: "https://example.invalid/v1") == replacement)
        try NanoMuseProviderHeaders.save([], instanceId: instance, baseURL: "https://example.invalid/v1")
        precondition(NanoMuseProviderHeaders.values(instanceId: instance, baseURL: "https://example.invalid/v1").isEmpty)
        print("Provider custom headers: validation, merging, redaction, origin binding and Keychain persistence passed")
    }
}
