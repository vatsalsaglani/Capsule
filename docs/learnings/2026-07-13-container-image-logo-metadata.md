# Container registries do not standardize image logos

**Context:** The Images card needs an optional product logo (MySQL, nginx,
Redis, Adminer) with a local cache and Capsule's existing blue optical-disc
symbol as the fallback.

**Finding:** As checked on 2026-07-13, the OCI image/registry metadata and the
documented Docker Hub repository response do not define a repository logo or
icon field. Docker Hub's current namespace repository endpoint returned
metadata such as description, categories, source, and storage size for
`library/mysql`, `library/nginx`, and `library/adminer`, but no `logo_url`.
Logo discovery therefore cannot be implemented as a portable registry call.

Docker's public `docker-library/docs` repository does maintain small PNG logos
for the official images checked here:

```sh
for name in mysql nginx redis adminer; do
  url="https://raw.githubusercontent.com/docker-library/docs/master/$name/logo.png"
  response=$(curl --silent --location --max-time 15 --output /dev/null \
    --write-out '%{http_code} %{content_type} %{size_download}' "$url")
  printf '%-8s %s\n' "$name" "$response"
done

# mysql    200 image/png 5062
# nginx    200 image/png 14732
# redis    200 image/png 6570
# adminer  200 image/png 4311
```

**Consequence:** Capsule should model icon lookup as an optional, injectable
provider in CapsuleKit rather than widening `ContainerRuntime`. The first
provider may resolve only public `docker.io/library/*` references through the
Docker Official Images documentation source. Cache by normalized repository
(`registry/namespace/name`, excluding tag and digest), store positive and
negative results on disk, enforce HTTPS/content-type/byte limits, and never
send private registry references or credentials to an external logo service.
Unknown, private, failed, or offline lookups retain the blue
`opticaldisc.fill` fallback.

**Implementation (2026-07-14):** `AppCore.ImageIconCache` is one
session-shared actor with one caller-facing operation, `data(for:)`. It
normalizes `mysql:8.4`, `docker.io/library/mysql:latest`, and Docker Hub alias
registries to the same cache key; it accepts only PNG responses up to 512 KiB
with a valid PNG signature. Positive files live in
`~/Library/Caches/Capsule/ImageIcons-v1/`; confirmed missing/invalid responses
have a 24-hour marker, while transport failures remain retryable. The cache
coalesces simultaneous requests and cancels owned fetches at teardown.

The SwiftUI `ContainerImageIcon` keeps an indigo ring and the blue optical-disc
fallback while it resolves. A downloaded brand image is decorative because the
adjacent image reference remains the accessible label.

Verification on 2026-07-14:

```sh
swift test --quiet
# 332 tests passed
xcodegen generate --spec App/project.yml --project App
xcodebuild -quiet -project App/Capsule.xcodeproj -scheme Capsule \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
