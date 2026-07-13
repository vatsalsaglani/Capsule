import Testing
@testable import ContainerClient

@Test func pullProgressParserHandlesObservedRuntimeShapes() throws {
    let phaseOnly = try #require(PullProgress(message: "[1/2] Fetching image [0s]").details)
    #expect(phaseOnly.phase.rawValue == "Fetching image")
    #expect(phaseOnly.stageIndex == 1)
    #expect(phaseOnly.stageCount == 2)
    #expect(phaseOnly.elapsed == .seconds(0))
    #expect(phaseOnly.percent == nil)

    let blobs = try #require(PullProgress(message: "[1/2] Fetching image (4 of 17 blobs) [3s]").details)
    #expect(blobs.completedBlobs == 4)
    #expect(blobs.totalBlobs == 17)

    let complete = try #require(PullProgress(
        message: "[1/2] Fetching image 7% (4 of 44 blobs, 65.0/944.7 MB, 4.7 MB/s) [11s]"
    ).details)
    #expect(complete.percent == 7)
    #expect(complete.completedBlobs == 4)
    #expect(complete.totalBlobs == 44)
    #expect(complete.transferredBytes == 65_000_000)
    #expect(complete.totalBytes == 944_700_000)
    #expect(complete.bytesPerSecond == 4_700_000)
    #expect(complete.elapsed == .seconds(11))
}

@Test func pullProgressParserSupportsLaterStagesBytesAndFractionalElapsed() throws {
    let details = try #require(PullProgress(
        message: "[2/2] Unpacking image 100% (44 of 44 blobs, 10 KB/2.5 MB, 291 bytes/s) [4.5s]"
    ).details)
    #expect(details.phase.rawValue == "Unpacking image")
    #expect(details.stageIndex == 2)
    #expect(details.stageCount == 2)
    #expect(details.percent == 100)
    #expect(details.transferredBytes == 10_000)
    #expect(details.totalBytes == 2_500_000)
    #expect(details.bytesPerSecond == 291)
    #expect(details.elapsed == .milliseconds(4_500))
}

@Test func pullProgressParserFailsOpenWithoutChangingRawMessage() throws {
    let malformed = PullProgress(message: "registry error: unauthorized")
    #expect(malformed.details == nil)
    #expect(malformed.message == "registry error: unauthorized")

    #expect(PullProgress(message: "[0/2] Fetching image [1s]").details == nil)
    #expect(PullProgress(message: "[3/2] Fetching image [1s]").details == nil)

    let outOfRange = try #require(PullProgress(message: "[1/2] Fetching image 101% [1s]").details)
    #expect(outOfRange.percent == nil)
    #expect(outOfRange.phase.rawValue == "Fetching image 101%")

    let overflow = try #require(PullProgress(
        message: "[1/2] Fetching image 10% (1 of 2 blobs, 999999999999999999999 TB/1 TB, 1 XB/s) [1s]"
    ).details)
    #expect(overflow.transferredBytes == nil)
    #expect(overflow.totalBytes == 1_000_000_000_000)
    #expect(overflow.bytesPerSecond == nil)
}

@Test func pullProgressParserRejectsFloatingPointIntegerBoundariesWithoutTrapping() throws {
    #expect(PullProgress(
        message: "[1/2] Fetching image [9223372036854775.808s]"
    ).details == nil)
    #expect(PullProgress(
        message: "[1/2] Fetching image [999999999999999999999999999999s]"
    ).details == nil)

    let byteBoundary = try #require(PullProgress(
        message: "[1/2] Fetching image 1% (1 of 2 blobs, 18446744073709551616 bytes/1 TB, 18446744073709551615 bytes/s) [1s]"
    ).details)
    #expect(byteBoundary.transferredBytes == nil)
    #expect(byteBoundary.totalBytes == 1_000_000_000_000)
    #expect(byteBoundary.bytesPerSecond == nil)
}
