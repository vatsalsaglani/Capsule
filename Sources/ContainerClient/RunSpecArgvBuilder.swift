import Foundation

/// Pure, deterministic `RunSpec` → `container create` argv builder (plan
/// §4.3, golden-tested against live-probed flag shapes). Targets `create`,
/// never `run` — see `RunSpec`'s doc comment for why.
///
/// Deterministic by construction: dictionary-backed fields (`environment`,
/// `labels`) are emitted sorted by key so two `RunSpec` values built from
/// different insertion orders produce byte-identical argv — required for any
/// future config-hash/idempotency check (labels §4.5) and for stable golden
/// tests.
///
/// Flag-group order is fixed (this exact order, always): `--name`,
/// `--entrypoint`, `-e` (sorted), `-w`, `-u`, `-p`, mounts (`-v`/`--tmpfs`, in
/// `mounts` array order), `--network` (in `networks` array order),
/// `--platform`, `--rosetta`, `--init`, `-l` (sorted), `--dns`,
/// `--dns-search`, `--dns-option`, `--dns-domain`, `--read-only`,
/// `--shm-size`, then the `image` positional, then trailing `command`
/// positionals.
extension RunSpec {
    public var createArguments: [String] {
        var arguments: [String] = []

        if let name { arguments.append(contentsOf: ["--name", name]) }
        if let entrypoint { arguments.append(contentsOf: ["--entrypoint", entrypoint]) }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        if let workingDirectory { arguments.append(contentsOf: ["-w", workingDirectory]) }
        if let user { arguments.append(contentsOf: ["-u", user]) }

        for port in ports {
            arguments.append(contentsOf: ["-p", port.argvValue])
        }

        for mount in mounts {
            arguments.append(contentsOf: mount.argvArguments)
        }

        for network in networks {
            arguments.append(contentsOf: ["--network", network])
        }

        if let platform { arguments.append(contentsOf: ["--platform", platform]) }
        if rosetta { arguments.append("--rosetta") }
        if useInit { arguments.append("--init") }

        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["-l", "\(key)=\(value)"])
        }

        if let dns {
            for nameserver in dns.nameservers { arguments.append(contentsOf: ["--dns", nameserver]) }
            for searchDomain in dns.searchDomains { arguments.append(contentsOf: ["--dns-search", searchDomain]) }
            for option in dns.options { arguments.append(contentsOf: ["--dns-option", option]) }
            if let domain = dns.domain { arguments.append(contentsOf: ["--dns-domain", domain]) }
        }

        if readOnly { arguments.append("--read-only") }
        if let shmSize { arguments.append(contentsOf: ["--shm-size", shmSize]) }

        arguments.append(image)
        arguments.append(contentsOf: command)

        return arguments
    }
}

extension PortMapping {
    /// `[hostAddress:]hostPort:containerPort/proto` — proto is always
    /// explicit (never relies on the runtime's default).
    fileprivate var argvValue: String {
        let hostPart = hostAddress.map { "\($0):\(hostPort)" } ?? String(hostPort)
        return "\(hostPart):\(containerPort)/\(proto.rawValue)"
    }
}

extension Mount {
    fileprivate var argvArguments: [String] {
        switch self {
        case .bind(let source, let target, let readOnly):
            return ["-v", "\(source):\(target)" + (readOnly ? ":ro" : "")]
        case .volume(let name, let target, let readOnly):
            return ["-v", "\(name):\(target)" + (readOnly ? ":ro" : "")]
        case .tmpfs(let target):
            return ["--tmpfs", target]
        }
    }
}
