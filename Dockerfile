# syntax=docker/dockerfile:1
#
# mobile-store worker image: the package compiled to one binary. The agent
# spawns it and dials it over gRPC/mTLS; it answers every action the package
# declares. Everything the scope talks to — AWS (STS, S3, Secrets Manager),
# Google's token endpoint, the Firebase App Distribution API — is reached
# through SDKs and REST from inside the binary: no aws CLI, no firebase CLI.
#
# At runtime the agent injects NP_GRPC_LISTEN (the port), the mTLS material
# (NP_WORKER_TLS_*) and NP_API_KEY. Never set NP_MODE=dev here: it switches
# the SDK to the in-memory platform client and no lifecycle is ever reported.
#
# The keyvault signing layer needs apksigner (the Android build-tools), which
# this image does NOT carry: the SDK is large and its license must be
# accepted. Scopes that sign with keyvault build a derived image that adds the
# build-tools and pin it in the agent.

# Base images come from the public ECR mirror of the Docker official images and
# bun from its GitHub release: Docker Hub rate-limits anonymous pulls from the
# shared CI runners (429) and breaks the build at random.
ARG ALPINE_IMAGE=public.ecr.aws/docker/library/alpine:3.20

# The build stage runs on the builder's own architecture and cross-compiles:
# bun targets any platform, so a multi-arch buildx emulates nothing here.
FROM --platform=$BUILDPLATFORM ${ALPINE_IMAGE} AS build
ARG BUILDARCH
ARG TARGETARCH
ARG BUN_VERSION=1.3.13
RUN apk add --no-cache curl unzip libstdc++ libgcc \
    && bunarch=$([ "${BUILDARCH:-amd64}" = "amd64" ] && echo x64 || echo aarch64) \
    && curl -fsSL -o /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bunarch}-musl.zip" \
    && unzip -q /tmp/bun.zip -d /tmp \
    && mv /tmp/bun-linux-*/bun /usr/local/bin/bun \
    && rm -rf /tmp/bun.zip /tmp/bun-linux-* \
    && bun --version
WORKDIR /opt/mobile-store
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile
COPY src ./src
# Compile for the image's own architecture (buildkit sets TARGETARCH; bun
# names amd64 "x64").
RUN arch=$([ "${TARGETARCH:-amd64}" = "amd64" ] && echo x64 || echo "$TARGETARCH") \
    && bun build --compile --target="bun-linux-${arch}-musl" src/main.ts --outfile /out/mobile-store

FROM ${ALPINE_IMAGE}
# The bun musl binary links libstdc++/libgcc dynamically; ca-certificates reach
# AWS, Google and Firebase. The worker runs as an unprivileged user with a
# writable HOME; the scratch directories live under /tmp/mobile-store.
RUN apk add --no-cache ca-certificates libstdc++ libgcc \
    && addgroup -S -g 65532 worker \
    && adduser -S -u 65532 -G worker -h /home/worker worker
COPY --from=build /out/mobile-store /app/packages/mobile-store/entrypoint
USER 65532
ENV HOME=/home/worker \
    SUPPRESS_NO_CONFIG_WARNING=1 \
    MOBILE_STORE_WORKDIR=/tmp/mobile-store \
    NP_AGENT_PLUGIN=np-agent-v1
ENTRYPOINT ["/app/packages/mobile-store/entrypoint"]
