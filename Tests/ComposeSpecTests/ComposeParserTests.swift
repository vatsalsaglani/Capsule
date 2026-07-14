import Foundation
import Testing
@testable import ComposeSpec

@Test func composeParserRejectsProjectNamesThatCanTraverseStoragePaths() throws {
    let yaml = "services:\n  web:\n    image: nginx\n"
    for invalidName in ["", ".", "..", "../escape", "nested/project", "nested\\project"] {
        #expect(throws: ComposeParseError.invalidProjectName(invalidName)) {
            _ = try ComposeParser().parse(yaml: yaml, projectName: invalidName)
        }
    }
}

private let fixture = """
name: demo-stack

services:
  web:
    image: docker.io/library/nginx:latest
    ports:
      - "8080:80"
    depends_on:
      db:
        condition: service_healthy

  db:
    image: docker.io/library/postgres:16
    environment:
      POSTGRES_PASSWORD: capsule
      POSTGRES_PORT: 5432
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 5

volumes:
  pgdata: {}
"""

@Test func parsesServicesDependenciesAndName() throws {
    let document = try ComposeParser().parse(yaml: fixture, fallbackName: "dir-name")
    #expect(document.projectName == "demo-stack")
    #expect(document.file.services.count == 2)
    #expect(document.support.findings.isEmpty)

    let web = try #require(document.file.services["web"])
    #expect(web.ports == [PortMapping(published: 8080, target: 80)])
    let requirement = try #require(web.dependsOn?.requirements["db"])
    #expect(requirement.condition == .serviceHealthy)

    let db = try #require(document.file.services["db"])
    #expect(db.environment?.entries["POSTGRES_PORT"] == "5432")
    #expect(db.environment?.entries["PGDATA"] == "/var/lib/postgresql/data/pgdata")
    #expect(db.healthcheck?.test?.values == ["CMD-SHELL", "pg_isready -U postgres"])
    #expect(ComposeDuration.parse(db.healthcheck?.interval ?? "") == .seconds(5))

    let mount = try #require(db.volumes?.first)
    #expect(mount.kind == .volume)
    #expect(mount.source == "pgdata")
    #expect(mount.target == "/var/lib/postgresql/data")

    #expect(document.file.namedVolumes.keys.contains("pgdata"))
}

@Test func explicitProjectNameWins() throws {
    let document = try ComposeParser().parse(yaml: fixture, projectName: "override")
    #expect(document.projectName == "override")
}

@Test func unknownKeysAreReportedNotDropped() throws {
    let yaml = """
    services:
      app:
        image: alpine
        blah: 1
        profiles: [debug]
    """
    let document = try ComposeParser().parse(yaml: yaml)
    let paths = document.support.findings.map(\.path)
    #expect(paths.contains("services.app.blah"))
    #expect(paths.contains("services.app.profiles"))
    #expect(!document.support.hasFatalFindings)
}

@Test func serviceWithoutImageOrBuildIsFatal() throws {
    let yaml = """
    services:
      app:
        command: ["sleep", "infinity"]
    """
    let document = try ComposeParser().parse(yaml: yaml)
    #expect(document.support.hasFatalFindings)
}

@Test func portShortSyntaxVariants() throws {
    #expect(try PortMapping(shortSyntax: "8080:80") == PortMapping(published: 8080, target: 80))
    #expect(try PortMapping(shortSyntax: "80") == PortMapping(published: nil, target: 80))
    #expect(
        try PortMapping(shortSyntax: "127.0.0.1:5432:5432/udp")
            == PortMapping(hostIP: "127.0.0.1", published: 5432, target: 5432, proto: "udp")
    )
    #expect(throws: ComposeSyntaxError.malformedPort("nope:80")) {
        try PortMapping(shortSyntax: "nope:80")
    }
}

@Test func volumeShortSyntaxDetectsBindsAndFlags() throws {
    let bind = try VolumeMount(shortSyntax: "./src:/app:ro")
    #expect(bind.kind == .bind)
    #expect(bind.readOnly)

    let named = try VolumeMount(shortSyntax: "data:/var/data")
    #expect(named.kind == .volume)
    #expect(!named.readOnly)

    #expect(throws: ComposeSyntaxError.malformedVolume("data:relative-target")) {
        try VolumeMount(shortSyntax: "data:relative-target")
    }
}

@Test func environmentListForm() throws {
    let yaml = """
    services:
      app:
        image: alpine
        environment:
          - FOO=bar
          - PASSTHROUGH
    """
    let document = try ComposeParser().parse(yaml: yaml)
    let env = try #require(document.file.services["app"]?.environment)
    #expect(env.entries["FOO"] == "bar")
    #expect(env.entries.keys.contains("PASSTHROUGH"))
    #expect(env.entries["PASSTHROUGH"] == String?.none)
}

@Test func restartModeSurvivesTheNorwayProblem() throws {
    // Unquoted `no` is YAML Bool(false); quoted "no" is a string. Both must
    // decode to .no.
    for yaml in ["restart: no", "restart: \"no\""] {
        let document = try ComposeParser().parse(yaml: """
        services:
          app:
            image: alpine
            \(yaml)
        """)
        #expect(document.file.services["app"]?.restart == .no)
    }
}

@Test func restartOnFailureWithRetries() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app:
        image: alpine
        restart: on-failure:3
    """)
    #expect(document.file.services["app"]?.restart == .onFailure(maxRetries: 3))
}

@Test func restartAlwaysIsAcceptedNowThatFrontendSupervisionIsResident() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app:
        image: alpine
        restart: always
    """)
    #expect(!document.support.findings.contains { $0.path == "services.app.restart" })
}

@Test func restartOnFailureReportsTheRuntimeExitStatusLimitation() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app:
        image: alpine
        restart: on-failure:3
    """)
    #expect(document.support.findings.contains {
        $0.path == "services.app.restart" && $0.severity == .warning
            && $0.message.contains("does not expose exit status")
    })
}

@Test func invalidStopGracePeriodIsFatal() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app:
        image: alpine
        stop_grace_period: eventually
    """)
    #expect(document.support.findings.contains {
        $0.path == "services.app.stop_grace_period" && $0.severity == .fatal
    })
}

@Test func interpolationOperators() throws {
    let vars = ["HOST": "db", "EMPTY": ""]
    #expect(try Interpolation.interpolate("$HOST:5432", variables: vars) == "db:5432")
    #expect(try Interpolation.interpolate("${HOST}", variables: vars) == "db")
    #expect(try Interpolation.interpolate("${MISSING:-fallback}", variables: vars) == "fallback")
    #expect(try Interpolation.interpolate("${EMPTY:-fallback}", variables: vars) == "fallback")
    #expect(try Interpolation.interpolate("${EMPTY-fallback}", variables: vars) == "")
    #expect(try Interpolation.interpolate("$$HOST", variables: vars) == "$HOST")
    #expect(throws: Interpolation.MissingVariableError.self) {
        try Interpolation.interpolate("${MISSING:?required}", variables: vars)
    }
}

@Test func composeDurationParsing() {
    #expect(ComposeDuration.parse("500ms") == .milliseconds(500))
    #expect(ComposeDuration.parse("1m30s") == .seconds(90))
    #expect(ComposeDuration.parse("2h") == .seconds(7200))
    #expect(ComposeDuration.parse("garbage") == nil)
    #expect(ComposeDuration.parse("5s extra") == nil)
}

@Test func resolvedConfigurationUsesComposeShapedScalarsAndMaps() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app:
        image: alpine:latest
        environment:
          PORT: 8080
        labels:
          capsule.example: true
        shm_size: 64m
    """)

    let rendered = try ComposePresentation.resolvedConfiguration(document)
    #expect(rendered.contains("environment:\n      PORT: '8080'"))
    #expect(rendered.contains("labels:\n      capsule.example: 'true'"))
    #expect(rendered.contains("shm_size: 64m"))
    #expect(!rendered.contains("entries:"))
    #expect(!rendered.contains("value:"))
}

@Test func composeSourceInterpolationPrecedenceIsExplicitAndSerializable() throws {
    let source = ComposeSource(
        yaml: """
        name: ${PROJECT}
        services:
          app:
            image: "example/${TAG}:${DOT_ONLY}-${FILE_ONLY}"
        """,
        fallbackName: "fallback",
        workingDirectory: "/tmp/demo",
        environment: ["PROJECT": "shell-project", "TAG": "shell"],
        dotEnv: "TAG=dot\nDOT_ONLY=dot-value\nPROJECT=dot-project",
        environmentFile: "TAG=file\nFILE_ONLY=file-value\nPROJECT=file-project"
    )
    let decodedSource = try JSONDecoder().decode(
        ComposeSource.self,
        from: JSONEncoder().encode(source)
    )
    #expect(decodedSource == source)

    let document = try ComposeParser().parse(source: decodedSource)
    #expect(document.projectName == "shell-project")
    #expect(document.file.services["app"]?.image == "example/shell:dot-value-file-value")
    #expect(document.environment["TAG"] == "shell")
    #expect(document.environment["DOT_ONLY"] == "dot-value")
    #expect(document.environment["FILE_ONLY"] == "file-value")
}

@Test func interpolationEnvironmentFilesCanReferenceMergedValues() throws {
    let document = try ComposeParser().parse(source: ComposeSource(
        yaml: """
        services:
          app: { image: "${REGISTRY}/${IMAGE}" }
        """,
        environment: ["HOST": "registry.example"],
        dotEnv: "REGISTRY=$HOST\nBASE=alpine",
        environmentFile: "IMAGE=${BASE}:latest"
    ))
    #expect(document.file.services["app"]?.image == "registry.example/alpine:latest")
    #expect(!document.support.hasFatalFindings)
}

@Test func interpolationTouchesScalarValuesButNotMappingKeys() throws {
    let document = try ComposeParser().parse(source: ComposeSource(
        yaml: """
        services:
          app:
            image: "${IMAGE}"
            environment:
              ${KEY}: "${VALUE}"
        """,
        environment: ["IMAGE": "alpine", "KEY": "EXPANDED", "VALUE": "yes"]
    ))
    let environment = try #require(document.file.services["app"]?.environment)
    #expect(document.file.services["app"]?.image == "alpine")
    #expect(environment.entries["${KEY}"] == "yes")
    #expect(environment.entries["EXPANDED"] == nil)
}

@Test func requiredInterpolationFailureIsAPathSpecificFatalFinding() throws {
    let document = try ComposeParser().parse(source: ComposeSource(yaml: """
    services:
      app:
        image: "${IMAGE:?set IMAGE before running compose}"
    """))
    let finding = try #require(document.support.findings.first {
        $0.path == "services.app.image"
    })
    #expect(finding.severity == .fatal)
    #expect(finding.message.contains("IMAGE"))
    #expect(document.support.hasFatalFindings)
}

@Test func malformedEnvironmentFilesFailLoud() throws {
    let document = try ComposeParser().parse(source: ComposeSource(
        yaml: """
        services:
          app: { image: alpine }
        """,
        dotEnv: "GOOD=value\nnot-an-assignment",
        environmentFile: "1INVALID=value"
    ))
    #expect(document.support.findings.contains { $0.path == ".env:2" && $0.severity == .fatal })
    #expect(document.support.findings.contains { $0.path == "--env-file:1" && $0.severity == .fatal })
}

@Test func serviceEnvironmentFilesMergeInOrderThenServiceEnvironmentWins() throws {
    let document = try ComposeParser().parse(source: ComposeSource(
        yaml: """
        services:
          app:
            image: alpine
            env_file: [base.env, override.env]
            environment:
              SHARED: service
              PASSTHROUGH:
        """,
        environment: ["HOST_VALUE": "from-host", "PASSTHROUGH": "host-pass"],
        serviceEnvironmentFiles: [
            "base.env": "BASE=one\nSHARED=base\nEXPANDED=$HOST_VALUE",
            "override.env": "SHARED=override\nLATER=two",
        ]
    ))
    let environment = try #require(document.file.services["app"]?.environment?.entries)
    #expect(environment["BASE"] == "one")
    #expect(environment["SHARED"] == "service")
    #expect(environment["EXPANDED"] == "from-host")
    #expect(environment["LATER"] == "two")
    #expect(environment["PASSTHROUGH"] == "host-pass")
    #expect(!document.support.hasFatalFindings)
}

@Test func missingServiceEnvironmentFileFailsLoud() throws {
    let document = try ComposeParser().parse(source: ComposeSource(yaml: """
    services:
      app:
        image: alpine
        env_file: missing.env
    """))
    #expect(document.support.findings.contains {
        $0.path == "services.app.env_file" && $0.severity == .fatal && $0.message.contains("missing.env")
    })
}

@Test func fileParserLoadsDotEnvExplicitEnvFileAndRelativeServiceEnvFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capsule-compose-spec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let compose = directory.appendingPathComponent("compose.yaml")
    let dotEnv = directory.appendingPathComponent(".env")
    let cliEnv = directory.appendingPathComponent("cli.env")
    let serviceEnv = directory.appendingPathComponent("service.env")
    try """
    services:
      app:
        image: "${IMAGE}"
        env_file: service.env
    """.write(to: compose, atomically: true, encoding: .utf8)
    try "IMAGE=from-dot".write(to: dotEnv, atomically: true, encoding: .utf8)
    try "IMAGE=from-cli-file".write(to: cliEnv, atomically: true, encoding: .utf8)
    try "SERVICE_VALUE=loaded".write(to: serviceEnv, atomically: true, encoding: .utf8)

    let document = try ComposeParser().parse(
        fileAt: compose,
        environment: ["IMAGE": "from-shell"],
        environmentFileURL: cliEnv
    )
    #expect(document.file.services["app"]?.image == "from-shell")
    #expect(document.file.services["app"]?.environment?.entries["SERVICE_VALUE"] == "loaded")
    #expect(!document.support.hasFatalFindings)
}

@Test func nestedUnsupportedKeysAreReported() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app:
        image: alpine
        build: { context: ., unsupported_build_option: true }
        ports:
          - { target: 80, published: 8080, mode: host }
    volumes:
      data: { driver: local }
    networks:
      default: { driver: bridge }
    """)
    let paths = Set(document.support.findings.map(\.path))
    #expect(paths.contains("services.app.build.unsupported_build_option"))
    #expect(paths.contains("services.app.ports[0].mode"))
    #expect(paths.contains("volumes.data.driver"))
    #expect(paths.contains("networks.default.driver"))
}

@Test func serviceNetworkMapAttachOnlySyntaxIsAcceptedAndOptionsReport() throws {
    let document = try ComposeParser().parse(yaml: """
    services:
      app:
        image: alpine
        networks:
          backend: {}
          frontend:
            aliases: [web]
    networks:
      backend: {}
      frontend: {}
    """)
    #expect(document.file.services["app"]?.networks?.values == ["backend", "frontend"])
    #expect(document.support.findings.contains {
        $0.path == "services.app.networks.frontend.aliases" && $0.severity == .warning
    })
}
