# syntax=docker/dockerfile:1
# Lending controller (U4 thin v0) — alpine + pinned kubectl/yq/jq running
# reconcile.sh. Non-root, works under readOnlyRootFilesystem: the only write
# path is $KUBECTL_CACHE_DIR, which the Deployment backs with an emptyDir
# mounted at /tmp.
#
# Build + load into the U1 kind harness:
#   docker build -t ghcr.io/nycterent/synorg/lending-controller:0.1.3 controllers/lending
#   kind load docker-image ghcr.io/nycterent/synorg/lending-controller:0.1.3 --name <cluster>
FROM alpine:3.20

# Pin kubectl to K8S_VERSION in scripts/validate.sh so client and validation
# target the same API surface.
ARG KUBECTL_VERSION=v1.33.0
ARG YQ_VERSION=v4.44.3
ARG TARGETARCH=amd64

# tzdata: the schedule's `timezone` field resolves region-local clock times.
RUN apk add --no-cache bash jq tzdata ca-certificates curl \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
    | sed 's|$|  /usr/local/bin/kubectl|' | sha256sum -c - \
 # yq is version-pinned by tag; upstream publishes no flat per-binary .sha256,
 # so integrity rides on the pinned release + TLS. Revisit if this image ever
 # ships beyond the pilot.
 && curl -fsSLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
 && chmod 0755 /usr/local/bin/kubectl /usr/local/bin/yq \
 && apk del curl

COPY reconcile.sh /usr/local/bin/reconcile.sh
RUN chmod 0755 /usr/local/bin/reconcile.sh

# Numeric non-root UID so runAsNonRoot admission can verify without a user db.
USER 65532:65532
ENV KUBECTL_CACHE_DIR=/tmp/kubectl-cache
ENTRYPOINT ["/usr/local/bin/reconcile.sh"]
