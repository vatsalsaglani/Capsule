import ContainerClient
import Supervisor
import Testing

@Test func driftReportFindsMissingChangedStoppedAndOrphanedServices() {
    let desired = [
        DesiredServiceInstance(
            service: "api",
            containerName: "payments-api-1",
            configHash: "new-api",
            shouldRun: true
        ),
        DesiredServiceInstance(
            service: "db",
            containerName: "payments-db-1",
            configHash: "db-hash",
            shouldRun: true
        ),
    ]
    let observed = [
        ContainerSummary(
            id: "payments-api-1",
            status: "stopped",
            imageReference: "demo/api",
            addresses: [],
            labels: [
                "capsule.project": "payments",
                "capsule.service": "api",
                "capsule.index": "1",
                "capsule.config-hash": "old-api",
            ]
        ),
        ContainerSummary(
            id: "payments-worker-1",
            status: "running",
            imageReference: "demo/worker",
            addresses: [],
            labels: [
                "capsule.project": "payments",
                "capsule.service": "worker",
                "capsule.index": "1",
                "capsule.config-hash": "worker-hash",
            ]
        ),
        ContainerSummary(
            id: "unrelated",
            status: "running",
            imageReference: "demo/other",
            addresses: [],
            labels: ["capsule.project": "other"]
        ),
    ]

    let report = DriftReconciler.report(project: "payments", desired: desired, observed: observed)
    #expect(report.findings.map(\.kind) == [
        .configurationChanged,
        .unexpectedState,
        .missing,
        .orphan,
    ])
    #expect(!report.isInSync)
}

@Test func matchingDesiredAndObservedStateHasNoDrift() {
    let desired = DesiredServiceInstance(
        service: "api",
        containerName: "payments-api-1",
        configHash: "api-hash",
        shouldRun: true
    )
    let observed = ContainerSummary(
        id: "payments-api-1",
        status: "running",
        imageReference: "demo/api",
        addresses: [],
        labels: [
            "capsule.project": "payments",
            "capsule.service": "api",
            "capsule.index": "1",
            "capsule.config-hash": "api-hash",
        ]
    )

    #expect(DriftReconciler.report(project: "payments", desired: [desired], observed: [observed]).isInSync)
}

@Test func intentionallyStoppedDesiredInstanceMayBeStoppedOrAbsentWithoutDrift() {
    let desired = DesiredServiceInstance(
        service: "api",
        containerName: "payments-api-1",
        configHash: "api-hash",
        shouldRun: false
    )
    let stopped = ContainerSummary(
        id: "payments-api-1",
        status: "stopped",
        imageReference: "demo/api",
        addresses: [],
        labels: [
            "capsule.project": "payments",
            "capsule.service": "api",
            "capsule.index": "1",
            "capsule.config-hash": "api-hash",
        ]
    )

    #expect(DriftReconciler.report(project: "payments", desired: [desired], observed: []).isInSync)
    #expect(DriftReconciler.report(project: "payments", desired: [desired], observed: [stopped]).isInSync)
}
