import AppCore
import Foundation
import Testing

private actor RecordingImageIconClient: ImageIconHTTPClient {
    private let response: ImageIconHTTPResponse
    private var requestedURLs: [URL] = []

    init(response: ImageIconHTTPResponse) {
        self.response = response
    }

    func fetch(_ url: URL) async throws -> ImageIconHTTPResponse {
        requestedURLs.append(url)
        return response
    }

    var requestCount: Int { requestedURLs.count }
}

private let pngData = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])

@Test func officialImageLogoURLsNormalizeTagsDigestsAndDockerHubAliases() {
    #expect(
        ImageIconCache.officialLogoURL(for: "mysql:8.4")?.absoluteString
            == "https://raw.githubusercontent.com/docker-library/docs/master/mysql/logo.png"
    )
    #expect(
        ImageIconCache.officialLogoURL(for: "index.docker.io/library/nginx@sha256:abc")?.absoluteString
            == "https://raw.githubusercontent.com/docker-library/docs/master/nginx/logo.png"
    )
    #expect(
        ImageIconCache.officialLogoURL(for: "docker.io/library/adminer:latest")?.absoluteString
            == "https://raw.githubusercontent.com/docker-library/docs/master/adminer/logo.png"
    )
}

@Test func customAndPrivateImageReferencesNeverTriggerLogoLookup() async throws {
    let client = RecordingImageIconClient(
        response: ImageIconHTTPResponse(data: pngData, statusCode: 200, contentType: "image/png")
    )
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ImageIconCache(cacheDirectory: directory, httpClient: client)

    #expect(await cache.data(for: "docker.io/redis/redisinsight:latest") == nil)
    #expect(await cache.data(for: "ghcr.io/acme/private-service:latest") == nil)
    #expect(await client.requestCount == 0)
}

@Test func positiveLogoResultsPersistAcrossTagsAndCacheInstances() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstClient = RecordingImageIconClient(
        response: ImageIconHTTPResponse(data: pngData, statusCode: 200, contentType: "image/png")
    )
    let cache = ImageIconCache(cacheDirectory: directory, httpClient: firstClient)

    #expect(await cache.data(for: "mysql:8.4") == pngData)
    #expect(await cache.data(for: "docker.io/library/mysql:latest") == pngData)
    #expect(await firstClient.requestCount == 1)

    let secondClient = RecordingImageIconClient(
        response: ImageIconHTTPResponse(data: Data(), statusCode: 500, contentType: nil)
    )
    let restoredCache = ImageIconCache(cacheDirectory: directory, httpClient: secondClient)
    #expect(await restoredCache.data(for: "mysql") == pngData)
    #expect(await secondClient.requestCount == 0)
}

@Test func negativeLogoResultsPersistWithoutRetrying() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstClient = RecordingImageIconClient(
        response: ImageIconHTTPResponse(data: Data(), statusCode: 404, contentType: nil)
    )
    let cache = ImageIconCache(cacheDirectory: directory, httpClient: firstClient)

    #expect(await cache.data(for: "redis:7") == nil)
    #expect(await cache.data(for: "docker.io/library/redis:latest") == nil)
    #expect(await firstClient.requestCount == 1)

    let secondClient = RecordingImageIconClient(
        response: ImageIconHTTPResponse(data: pngData, statusCode: 200, contentType: "image/png")
    )
    let restoredCache = ImageIconCache(cacheDirectory: directory, httpClient: secondClient)
    #expect(await restoredCache.data(for: "redis") == nil)
    #expect(await secondClient.requestCount == 0)
}

@Test func invalidLogoPayloadsAreNegativeCached() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = RecordingImageIconClient(
        response: ImageIconHTTPResponse(data: Data("not a png".utf8), statusCode: 200, contentType: "text/plain")
    )
    let cache = ImageIconCache(cacheDirectory: directory, httpClient: client)

    #expect(await cache.data(for: "nginx:latest") == nil)
    #expect(await cache.data(for: "nginx:stable") == nil)
    #expect(await client.requestCount == 1)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "capsule-image-icon-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
