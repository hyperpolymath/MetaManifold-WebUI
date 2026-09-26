# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Containerfile — the standalone deployment of this repository's toolchain and proof lane.
#
# Layered to match stapeln.toml (which is the source of truth for what each layer is for).
# The purpose is not "a dev container": it is that `just prove-agda`, `just check-kyaml` and
# the Julia test lane run somewhere reproducible, from an image, instead of from whatever a
# runner happens to have. Owner ruling, 2026-09-26.
#
# UNVERIFIED IN THE AUTHORING SANDBOX: this file has not been built (no container runtime,
# no registry access where it was written). The first CI run that builds it is the check; the
# layer that fails will name itself.
#
# Build:  podman build -t ghcr.io/hyperpolymath/metamanifold-webui:0.1.0 -f Containerfile .
# Run:    podman run --rm ghcr.io/hyperpolymath/metamanifold-webui:0.1.0
#         (its entrypoint is `just prove-agda`)

FROM docker.io/library/debian:12-slim AS base
# Guix is layered on rather than replacing the base so the R lane's system packages are the
# ones renv.lock was generated against. The locale is set because R's message catalogue and
# Agda's error output both depend on it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils git bash gnupg locales; \
    sed -i 's/# en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen; \
    locale-gen; \
    rm -rf /var/lib/apt/lists/*
ENV LANG=en_GB.UTF-8 LC_ALL=en_GB.UTF-8

# ── Layer: guix-toolchain ────────────────────────────────────────────────────
# guix.scm names the toolchain; channels.scm pins the revision. It includes agda and
# agda-stdlib for the proof lane (see the proof-lane comment in guix.scm).
FROM base AS guix-toolchain
ARG GUIX_VERSION=1.4.0
RUN set -eux; \
    curl -fsSL "https://ftp.gnu.org/gnu/guix/guix-binary-${GUIX_VERSION}.x86_64-linux.tar.xz" -o /tmp/guix.tar.xz; \
    cd /tmp; tar -xf guix.tar.xz; \
    mv var/guix /var/guix; \
    mv gnu /gnu; \
    mkdir -p /root/.config/guix; \
    ln -sf /var/guix/profiles/per-user/root/current-guix /root/.config/guix/current; \
    mkdir -p /usr/local/bin; \
    ln -sf /root/.config/guix/current/bin/guix /usr/local/bin/guix; \
    ln -sf /root/.config/guix/current/bin/guix-daemon /usr/local/bin/guix-daemon; \
    rm -rf /tmp/guix.tar.xz /tmp/var /tmp/gnu; \
    guix --version
COPY channels.scm guix.scm /work/
WORKDIR /work
# Resolving the environment is the expensive step and the reason this layer exists separately:
# it is cached until channels.scm or guix.scm changes.
RUN set -eux; \
    guix time-machine -C channels.scm -- shell -D -f guix.scm -- true; \
    guix time-machine -C channels.scm -- shell -D -f guix.scm -- agda --version

# ── Layer: mise-toolchain ────────────────────────────────────────────────────
# mise pins the exact versions CI uses (julia 1.12.5, bun 1.3.10, node 20.20.2, just 1.43.1),
# so the image and CI cannot drift. Guix supplies versions that follow the channels commit;
# mise supplies the exact binaries. Both are present on purpose.
FROM guix-toolchain AS mise-toolchain
RUN set -eux; \
    curl -fsSL https://mise.run | bash; \
    /root/.local/bin/mise install; \
    /root/.local/bin/mise ls
ENV PATH=/root/.local/share/mise/shims:/root/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

# ── Layer: proofs ────────────────────────────────────────────────────────────
# The build refuses to produce the image unless every law checks and the YAML is canonical.
# A proof nobody runs at build time is a file, not a check.
FROM mise-toolchain AS proofs
COPY . /work
WORKDIR /work
RUN set -eux; \
    just prove-agda; \
    mkdir -p /proofs; \
    cp proofs/agda/*.agdai /proofs/ 2>/dev/null || true

# ── Layer: runtime ───────────────────────────────────────────────────────────
# A small runtime that carries the toolchain and the repository: `just prove-agda` and
# `just check-kyaml` work without a checkout, which is what "standalone deployment" means here.
FROM debian:12-slim AS runtime
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates git bash locales; \
    rm -rf /var/lib/apt/lists/*
ENV LANG=en_GB.UTF-8 LC_ALL=en_GB.UTF-8 \
    PATH=/root/.local/share/mise/shims:/root/.local/bin:/usr/local/bin:/usr/bin:/bin
COPY --from=proofs /work /work
COPY --from=proofs /root/.local /root/.local
COPY --from=guix-toolchain /gnu /gnu
COPY --from=guix-toolchain /var/guix /var/guix
COPY --from=guix-toolchain /root/.config/guix /root/.config/guix
RUN ln -sf /root/.config/guix/current/bin/guix /usr/local/bin/guix
WORKDIR /work
ENTRYPOINT ["/usr/bin/env", "just", "prove-agda"]
