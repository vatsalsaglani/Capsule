import ComposeRuntime
import Foundation
import Observation

/// Main-actor projection of the UI-free supervisor snapshot. One instance is
/// shared by every Compose screen in the app.
@MainActor
@Observable
public final class ComposeSupervisionStore {
    public private(set) var snapshot: ComposeSupervisionSnapshot?
    public private(set) var errorMessage: String?

    public init() {}

    func receive(_ snapshot: ComposeSupervisionSnapshot) {
        self.snapshot = snapshot
        errorMessage = nil
    }

    func receive(error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }

    public func project(_ projectID: String) -> ProjectSupervisionSnapshot? {
        snapshot?.projects.first { $0.projectID == projectID }
    }
}
