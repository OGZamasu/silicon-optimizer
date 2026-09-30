import Foundation
import Observation
import SiliconElevenLabs

/// The Explorer's list and filters, and the form and runner of each operation opened this
/// session — kept, so going back to one finds what was typed there.
@MainActor
@Observable
final class ElevenLabsExplorerModel {

    enum DeprecatedFilter: String, CaseIterable, Identifiable {
        case show, hide, only
        var id: String { rawValue }
        var title: String {
            switch self {
            case .show: "Include deprecated"
            case .hide: "Hide deprecated"
            case .only: "Only deprecated"
            }
        }
    }

    /// One operation opened in the Explorer.
    @MainActor
    final class Session {
        let operation: ElevenLabsOperation
        let form: ElevenLabsFormModel
        let runner: ElevenLabsRunner

        init(operation: ElevenLabsOperation, context: ElevenLabsRunner.Context) {
            self.operation = operation
            form = ElevenLabsFormModel(operation: operation)
            runner = ElevenLabsRunner(operation: operation, context: context)
        }
    }

    var search = ""
    /// Risk classes to show; empty shows every one.
    var risks: Set<ElevenLabsRisk> = []
    var billableOnly = false
    var deprecated: DeprecatedFilter = .show

    @ObservationIgnored private let catalog: [ElevenLabsOperation]
    @ObservationIgnored private let context: ElevenLabsRunner.Context
    @ObservationIgnored private var sessions: [String: Session] = [:]

    init(catalog: [ElevenLabsOperation] = ElevenLabsCatalog.all, context: ElevenLabsRunner.Context) {
        self.catalog = catalog
        self.context = context
    }

    var total: Int { catalog.count }

    /// Whether any filter narrows the list.
    var isFiltered: Bool {
        !risks.isEmpty || billableOnly || deprecated != .show
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The operations that pass the search and filters.
    var matching: [ElevenLabsOperation] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        return catalog.filter { operation in
            if !risks.isEmpty, !risks.contains(operation.risk) { return false }
            if billableOnly, !operation.billable { return false }
            switch deprecated {
            case .show: break
            case .hide: if operation.deprecated { return false }
            case .only: if !operation.deprecated { return false }
            }
            guard !words.isEmpty else { return true }
            let haystack = [operation.id, operation.method, operation.path, operation.summary, operation.group]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// `matching`, by display group in catalog order.
    var grouped: [(group: String, operations: [ElevenLabsOperation])] {
        var order: [String] = []
        var byGroup: [String: [ElevenLabsOperation]] = [:]
        for operation in matching {
            if byGroup[operation.group] == nil { order.append(operation.group) }
            byGroup[operation.group, default: []].append(operation)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    func toggle(_ risk: ElevenLabsRisk) {
        if risks.contains(risk) { risks.remove(risk) } else { risks.insert(risk) }
    }

    func clearFilters() {
        search = ""
        risks = []
        billableOnly = false
        deprecated = .show
    }

    /// The session for `operationID`, made on first use.
    func session(for operationID: String) -> Session? {
        if let existing = sessions[operationID] { return existing }
        guard let operation = catalog.first(where: { $0.id == operationID }) else { return nil }
        let session = Session(operation: operation, context: context)
        sessions[operationID] = session
        return session
    }

    /// Checks the form and runs the operation; the form shows every problem either finds.
    func run(_ session: Session) {
        let built = session.form.arguments()
        session.form.setProblems(built.problems)
        guard built.problems.isEmpty else { return }
        Task {
            await session.runner.perform(arguments: built.arguments, files: built.files)
            session.form.setProblems(session.runner.problems)
        }
    }

    /// What Run would send, as a curl command with the key left to the reader — or the
    /// problems that stop it being sent.
    func curl(for session: Session) -> Result<String, CurlProblem> {
        let built = session.form.arguments()
        guard built.problems.isEmpty else { return .failure(CurlProblem(problems: built.problems)) }
        guard let client = context.client() else {
            return .failure(CurlProblem(problems: [ElevenLabsError.notLinked.description]))
        }
        do {
            let call = try client.describe(session.operation.id, arguments: built.arguments, files: built.files)
            return .success(ElevenLabsCurl.command(for: call, files: built.files))
        } catch ElevenLabsError.invalidArguments(let problems) {
            return .failure(CurlProblem(problems: problems))
        } catch {
            return .failure(CurlProblem(problems: [ElevenLabsRunnerFailure(error).message]))
        }
    }

    struct CurlProblem: Error, Equatable {
        var problems: [String]
    }
}
