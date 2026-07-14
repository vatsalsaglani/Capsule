import ContainerClient
import Foundation
import Observation

@MainActor
@Observable
public final class VolumesStore {
    public enum Phase: Equatable { case loading, loaded([VolumeRecord]), failed(String) }
    public private(set) var phase: Phase = .loading
    public private(set) var actionError: String?
    private let runtime: any ContainerRuntime

    public init(runtime: any ContainerRuntime) { self.runtime = runtime }

    public func refresh() async {
        do { phase = .loaded(try await RuntimeResourceInventory.load(from: runtime).volumes) }
        catch { phase = .failed(Self.message(error)) }
    }

    public func create(name: String, capacityBytes: UInt64?) async {
        actionError = nil
        do {
            try await runtime.createVolume(VolumeCreateSpec(name: name, capacityBytes: capacityBytes))
            await refresh()
        } catch { actionError = Self.message(error) }
    }

    public func delete(_ volume: VolumeRecord) async {
        actionError = nil
        do { try await runtime.deleteVolume(name: volume.summary.name); await refresh() }
        catch { actionError = Self.message(error) }
    }

    public func prune() async {
        actionError = nil
        do { _ = try await runtime.pruneVolumes(); await refresh() }
        catch { actionError = Self.message(error) }
    }

    public func dismissError() { actionError = nil }
    private nonisolated static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

@MainActor
@Observable
public final class NetworksStore {
    public enum Phase: Equatable { case loading, loaded([NetworkRecord]), failed(String) }
    public private(set) var phase: Phase = .loading
    public private(set) var actionError: String?
    private let runtime: any ContainerRuntime

    public init(runtime: any ContainerRuntime) { self.runtime = runtime }

    public func refresh() async {
        do { phase = .loaded(try await RuntimeResourceInventory.load(from: runtime).networks) }
        catch { phase = .failed(Self.message(error)) }
    }

    public func create(name: String, isInternal: Bool, ipv4Subnet: String?, ipv6Subnet: String?) async {
        actionError = nil
        do {
            try await runtime.createNetwork(NetworkCreateSpec(
                name: name,
                connectivity: isInternal ? .hostOnly : .nat,
                ipv4Subnet: ipv4Subnet,
                ipv6Subnet: ipv6Subnet
            ))
            await refresh()
        } catch { actionError = Self.message(error) }
    }

    public func delete(_ network: NetworkRecord) async {
        actionError = nil
        guard !network.isBuiltIn else { actionError = "The built-in network cannot be deleted."; return }
        do { try await runtime.deleteNetwork(name: network.summary.name); await refresh() }
        catch { actionError = Self.message(error) }
    }

    public func prune() async {
        actionError = nil
        do { _ = try await runtime.pruneNetworks(); await refresh() }
        catch { actionError = Self.message(error) }
    }

    public func dismissError() { actionError = nil }
    private nonisolated static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
