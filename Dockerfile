# syntax=docker/dockerfile:1.7
#
# DJS development image. The build stage pins the same Ubuntu 24.04
# toolchain/libraries as docs/PINS.md; the runtime stage carries only the
# executable and the shared libraries it loads.
#
#   docker build -t djs .
#   docker run --rm djs --version
#   docker build --target test -t djs:test .   # integration suite
#
FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake git ldc dub netbase ninja-build \
      openssl pkg-config procps \
      libuv1-dev libssl-dev libbrotli-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Keep the pinned QuickJS-NG build in its own layer. Source changes below do
# not invalidate this step.
COPY scripts/bootstrap.sh scripts/bootstrap.sh
COPY scripts/patches/quickjs-array-buffer-accounting.patch scripts/patches/quickjs-array-buffer-accounting.patch
RUN mkdir -p vendor && ./scripts/bootstrap.sh

COPY . .

RUN dub build --build=release --compiler=ldc2 \
 && ./djs --version \
 && ./djs -A -e 'console.log(process.platform, process.arch)' \
 && ./djs -A tests/js/cjs_reexports/main.mjs

# Optional target: run the full golden-output and CLI integration suite.
FROM build AS test
RUN ./scripts/integration.sh

# Runtime image: the executable plus the libraries from `ldd`.
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates libbrotli1 libphobos2-ldc-shared106 \
      libssl3t64 libuv1t64 netbase tzdata zlib1g \
 && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="DJS" \
      org.opencontainers.image.description="A small embeddable JavaScript runtime written in D" \
      org.opencontainers.image.source="https://github.com/amscotti/djs" \
      org.opencontainers.image.licenses="MIT"

COPY --from=build /src/djs /usr/local/bin/djs
COPY --from=build /src/examples /opt/djs/examples
COPY --from=build /src/docs/COMPAT.md /opt/djs/docs/COMPAT.md
COPY --from=build /src/README.md /opt/djs/README.md
COPY --from=build /src/LICENSE /opt/djs/LICENSE
COPY --from=build /src/THIRD_PARTY.md /opt/djs/THIRD_PARTY.md

# Mount a project here:
#   docker run --rm -v "$PWD:/work" -w /work djs -A app.js
WORKDIR /work
ENTRYPOINT ["djs"]
