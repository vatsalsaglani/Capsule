import ArgumentParser
import ContainerClient

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List containers (project grouping arrives with compose in M2)."
    )

    @Flag(name: .shortAndLong, help: "Include containers that are not running.")
    var all = false

    func run() async throws {
        let client = try CLIProcessClient()
        let containers = try await client.listContainers(all: all)
        guard !containers.isEmpty else {
            print(all ? "No containers." : "No running containers (try --all).")
            return
        }

        let rows = [["ID", "STATE", "IMAGE", "ADDRESSES"]] + containers.map {
            [
                $0.id,
                $0.status,
                $0.imageReference ?? "-",
                $0.addresses.isEmpty ? "-" : $0.addresses.joined(separator: ", "),
            ]
        }
        let widths = (0..<4).map { column in
            rows.map { $0[column].count }.max() ?? 0
        }
        for row in rows {
            let line = zip(row, widths)
                .map { text, width in text.padding(toLength: width + 2, withPad: " ", startingAt: 0) }
                .joined()
            print(line)
        }
    }
}
