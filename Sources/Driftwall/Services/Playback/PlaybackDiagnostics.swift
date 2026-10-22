import Foundation

/// Live decoder counts, shown in Settings › About and printed by the perf harness. A counter is only
/// ever touched on the main actor when a decoder is created or released, so it costs nothing per frame.
@MainActor
enum PlaybackDiagnostics {
    enum Kind: String, CaseIterable { case desktop, preview }

    private(set) static var live: [Kind: Int] = [:]
    private(set) static var created: [Kind: Int] = [:]

    static func opened(_ kind: Kind) {
        live[kind, default: 0] += 1
        created[kind, default: 0] += 1
    }

    static func closed(_ kind: Kind) {
        live[kind, default: 0] = max(0, live[kind, default: 0] - 1)
    }

    static var summary: String {
        Kind.allCases.map { "\($0.rawValue) \(live[$0, default: 0]) live / \(created[$0, default: 0]) created" }.joined(separator: ", ")
    }
}
