import Foundation

/// The policy for every ElevenLabs operation: its risk class, whether it spends credits, and
/// whether its answer carries a credential. Until the reviewed lists land, every operation
/// takes `defaultRisk(method:path:)`: a read for GET, real-world inside the families below,
/// destructive for everything else.
enum ElevenLabsRiskTable {

    /// Path patterns whose non-GET operations are all `realWorld`.
    static let realWorldFamilies: [String] = [
        #"^/v1/convai/(twilio|exotel|whatsapp|sip-trunk)/"#,   // outbound calls and messages
        #"^/v1/convai/batch-calling/"#,                         // submit/retry place real calls
        #"^/v1/convai/(v2/)?phone-numbers(/|$)"#,
        #"^/v1/convai/whatsapp-accounts(/|$)"#,
        #"^/v1/convai/secrets(/|$)"#,
        #"^/v1/convai/mcp-servers(/|$)"#,                      // connects agents to outside tools
        #"^/v1/convai/settings(/|$)"#,
        #"^/v1/workspace/(invites|members|groups|webhooks|auth-connections|resources)(/|$)"#,
        #"^/v1/service-accounts(/|$)"#,                        // including their API keys
        #"^/v1/workspaces/api-keys/"#,
    ]

    private static let familyExpressions = realWorldFamilies.map { try! NSRegularExpression(pattern: $0) }

    static func isInRealWorldFamily(_ path: String) -> Bool {
        familyExpressions.contains {
            $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
    }

    /// The class of an operation this table has never seen.
    static func defaultRisk(method: String, path: String) -> ElevenLabsRisk {
        if method.uppercased() == "GET" { return .read }
        if isInRealWorldFamily(path) { return .realWorld }
        return .destructive
    }

    static func risk(for id: String, method: String, path: String) -> ElevenLabsRisk {
        table[id] ?? defaultRisk(method: method, path: path)
    }

    /// Spends credits or money. Every `generate` operation, plus the real-world ones that
    /// bill by the minute or the order.
    static func isBillable(_ id: String, risk: ElevenLabsRisk) -> Bool {
        risk == .generate || billableBeyondGenerate.contains(id)
    }

    static func returnsCredential(_ id: String) -> Bool { credentialFields[id] != nil }

    /// Operations whose answer carries a credential, and the fields that hold it.
    static let credentialFields: [String: [String]] = [:]

    /// Real-world operations that bill.
    static let billableBeyondGenerate: Set<String> = []

    /// The reviewed classes, by operation id. Empty until the table is filled in.
    static let table: [String: ElevenLabsRisk] = [:]
}
