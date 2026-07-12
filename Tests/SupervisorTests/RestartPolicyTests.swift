import Testing
@testable import Supervisor

@Test func backoffDoublesFrom100msAndCapsAtOneMinute() {
    #expect(RestartPolicy.backoffDelay(attempt: 0) == .milliseconds(100))
    #expect(RestartPolicy.backoffDelay(attempt: 1) == .milliseconds(200))
    #expect(RestartPolicy.backoffDelay(attempt: 3) == .milliseconds(800))
    #expect(RestartPolicy.backoffDelay(attempt: 10) == .milliseconds(60_000))
    #expect(RestartPolicy.backoffDelay(attempt: 1000) == .milliseconds(60_000))
    #expect(RestartPolicy.backoffDelay(attempt: -5) == .milliseconds(100))
}

@Test func manualStopAlwaysWins() {
    for policy: RestartPolicy in [.never, .always, .unlessStopped, .onFailure(maxRetries: nil)] {
        #expect(!policy.shouldRestart(exitCode: 1, wasStoppedByUser: true, attemptsSoFar: 0))
    }
}

@Test func onFailureRestartsOnlyOnNonZeroExitWithinBudget() {
    let policy = RestartPolicy.onFailure(maxRetries: 3)
    #expect(!policy.shouldRestart(exitCode: 0, wasStoppedByUser: false, attemptsSoFar: 0))
    #expect(policy.shouldRestart(exitCode: 1, wasStoppedByUser: false, attemptsSoFar: 2))
    #expect(!policy.shouldRestart(exitCode: 1, wasStoppedByUser: false, attemptsSoFar: 3))

    let unbounded = RestartPolicy.onFailure(maxRetries: nil)
    #expect(unbounded.shouldRestart(exitCode: 137, wasStoppedByUser: false, attemptsSoFar: 500))
}

@Test func alwaysAndUnlessStoppedRestartOnAnyExit() {
    for policy: RestartPolicy in [.always, .unlessStopped] {
        #expect(policy.shouldRestart(exitCode: 0, wasStoppedByUser: false, attemptsSoFar: 10))
        #expect(policy.shouldRestart(exitCode: 137, wasStoppedByUser: false, attemptsSoFar: 10))
    }
}
