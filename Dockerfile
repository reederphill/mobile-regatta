# The race server and the load client (#67), for Linux. Multi-stage: build with the pinned Swift image, run on
# plain Ubuntu with the Swift runtime linked in statically. Nothing host-specific: builds for either
# architecture, but only linux/amd64 is the authoritative replay platform (ADR 0002), so deploy that:
#
#   podman build --platform linux/amd64 -t regatta-server .
#   podman run --rm -e ENV=dev -p 8080:8080 regatta-server
#   podman run --rm --network host --entrypoint regatta-loadclient regatta-server --clients 16 --race-seconds 20
#
# See README.md for the variables it reads. It refuses to start unless ENV=dev.

# The toolchain of the replay platform (scripts/linux-test.sh, `replayPlatform`).
FROM swift:6.3.3-noble AS build
WORKDIR /src
# Only the packages: the app isn't needed, and .dockerignore keeps local build products out.
COPY Packages/ Packages/
RUN swift build -c release --static-swift-stdlib --package-path Packages/RegattaServer \
        --product RegattaServer \
    && swift build -c release --static-swift-stdlib --package-path Packages/RegattaServer \
        --product regatta-loadclient \
    && mkdir -p /out \
    && bin="$(swift build -c release --package-path Packages/RegattaServer --show-bin-path)" \
    && cp "$bin/RegattaServer" "$bin/regatta-loadclient" /out/ \
    && cp -R "$bin"/*.resources /out/

# Ubuntu 24.04: glibc 2.39, the C library of the simulation version (ADR 0002).
FROM ubuntu:24.04
COPY --from=build /out/ /app/
ENV PATH=/app:$PATH HOST=0.0.0.0 PORT=8080
EXPOSE 8080
USER 65534:65534
ENTRYPOINT ["RegattaServer"]
