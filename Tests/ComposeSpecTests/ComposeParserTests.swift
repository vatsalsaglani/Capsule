import Testing
@testable import ComposeSpec

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
