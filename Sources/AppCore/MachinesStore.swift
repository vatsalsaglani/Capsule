import ContainerClient
import Foundation
import Observation

public struct MachineCreationInput: Sendable, Hashable {
    public var imageReference: String
    public var name: String
    public var platform: String
    public var cpus: Int?
    public var memoryGiB: Int?
    public var homeMount: MachineHomeMount
    public var bootAfterCreation: Bool
    public var setAsDefault: Bool
    public var nestedVirtualization: Bool

    public init(
        imageReference: String,
        name: String = "",
        platform: String = "",
        cpus: Int? = nil,
        memoryGiB: Int? = nil,
        homeMount: MachineHomeMount = .readWrite,
        bootAfterCreation: Bool = true,
        setAsDefault: Bool = false,
        nestedVirtualization: Bool = false
    ) {
        self.imageReference = imageReference
        self.name = name
        self.platform = platform
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.homeMount = homeMount
        self.bootAfterCreation = bootAfterCreation
        self.setAsDefault = setAsDefault
        self.nestedVirtualization = nestedVirtualization
    }

    public func spec() throws -> MachineCreateSpec {
        let image = imageReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { throw MachineCreationInputError.missingImage }
        if let cpus, cpus < 1 { throw MachineCreationInputError.invalidCPUCount }
        if let memoryGiB, memoryGiB < 1 { throw MachineCreationInputError.invalidMemory }

        let bytes: UInt64?
        if let memoryGiB {
            let (value, overflow) = UInt64(memoryGiB).multipliedReportingOverflow(by: 1_073_741_824)
            guard !overflow else { throw MachineCreationInputError.invalidMemory }
            bytes = value
        } else {
            bytes = nil
        }

        return MachineCreateSpec(
            imageReference: image,
            name: name.nilIfBlank,
            platform: platform.nilIfBlank,
            cpus: cpus,
            memoryBytes: bytes,
            homeMount: homeMount,
            bootAfterCreation: bootAfterCreation,
            setAsDefault: setAsDefault,
            nestedVirtualization: nestedVirtualization
        )
    }
}

public enum MachineCreationInputError: Error, Sendable, Equatable, LocalizedError {
    case missingImage
    case invalidCPUCount
    case invalidMemory

    public var errorDescription: String? {
        switch self {
        case .missingImage: "A machine image is required."
        case .invalidCPUCount: "CPU count must be at least 1."
        case .invalidMemory: "Memory must be at least 1 GiB and fit in the runtime's byte range."
        }
    }
}

@MainActor
@Observable
public final class MachinesStore {
    public enum Phase: Equatable {
        case loading
        case loaded([MachineSummary])
        case failed(String)
    }

    public enum Action: Equatable {
        case idle
        case working(machineID: String?)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var selectedMachineID: String?
    public private(set) var selectedDetail: MachineDetail?
    public private(set) var action: Action = .idle
    public private(set) var lastError: String?
    public private(set) var logMachineID: String?
    public private(set) var logSource: MachineLogSource = .standard
    public private(set) var logLines: [LogLine] = []
    public private(set) var logError: String?

    private let runtime: any ContainerRuntime
    @ObservationIgnored private var logTask: Task<Void, Never>?

    public init(runtime: any ContainerRuntime) {
        self.runtime = runtime
    }

    deinit { logTask?.cancel() }

    public var machines: [MachineSummary] {
        if case .loaded(let machines) = phase { machines } else { [] }
    }

    public func refresh() async {
        if machines.isEmpty { phase = .loading }
        do {
            let values = try await runtime.listMachines()
            phase = .loaded(values.sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            })
            if let selectedDetail,
               values.contains(where: { $0.id == selectedDetail.id }) {
                await select(id: selectedDetail.id)
            } else if selectedDetail != nil {
                selectedMachineID = nil
                selectedDetail = nil
            }
        } catch {
            phase = .failed(message(for: error))
        }
    }

    public func select(id: String) async {
        selectedMachineID = id
        selectedDetail = nil
        do {
            selectedDetail = try await runtime.inspectMachine(id: id)
        } catch {
            lastError = message(for: error)
        }
    }

    public func create(_ input: MachineCreationInput) async {
        do {
            await create(try input.spec())
        } catch {
            lastError = message(for: error)
        }
    }

    public func create(_ spec: MachineCreateSpec) async {
        await perform(machineID: spec.name) {
            let id = try await self.runtime.createMachine(spec)
            await self.refresh()
            await self.select(id: id)
        }
    }

    public func start(id: String) async {
        await perform(machineID: id) {
            try await self.runtime.startMachine(id: id)
            await self.refresh()
        }
    }

    public func stop(id: String) async {
        await perform(machineID: id) {
            try await self.runtime.stopMachine(id: id)
            await self.refresh()
        }
    }

    public func delete(id: String) async {
        await perform(machineID: id) {
            try await self.runtime.deleteMachine(id: id)
            if self.selectedMachineID == id {
                self.selectedMachineID = nil
                self.selectedDetail = nil
            }
            await self.refresh()
        }
    }

    public func showLogs(id: String, source: MachineLogSource) async {
        logTask?.cancel()
        logMachineID = id
        logSource = source
        logLines = []
        logError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await runtime.machineLogs(
                    id: id,
                    source: source,
                    follow: true,
                    tail: 300
                )
                for try await line in stream {
                    guard !Task.isCancelled else { return }
                    self.logLines.append(line)
                    if self.logLines.count > 2_000 {
                        self.logLines.removeFirst(self.logLines.count - 2_000)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.logError = self.message(for: error)
            }
        }
        logTask = task
        await task.value
    }

    public func stopLogs() {
        logTask?.cancel()
        logTask = nil
    }

    public func dismissError() { lastError = nil }

    private func perform(
        machineID: String?,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async {
        action = .working(machineID: machineID)
        lastError = nil
        do {
            try await operation()
        } catch {
            lastError = message(for: error)
        }
        action = .idle
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
