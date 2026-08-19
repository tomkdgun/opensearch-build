# Copyright OpenSearch Contributors
# SPDX-License-Identifier: Apache-2.0

# Multi-architecture OpenSearch Dashboards image based on Red Hat UBI9 Node.js minimal.
# Supports: linux/amd64 (x64), linux/arm64, linux/ppc64le, linux/s390x.
#
# Key design: the bundled node/ directory from the x64 tarball is removed so that
# OpenSearch Dashboards' use_node script falls through to the arch-native Node.js
# binary provided by the ubi9/nodejs-22-minimal base image. The tarball itself
# (built once on x64) contains only pure JavaScript — no native .node addons —
# and is therefore portable across all four architectures unchanged.
#
# Node resolution order in bin/use_node:
#   1. $OSD_NODE_HOME/bin/node  (env var override)
#   2. $NODE_HOME/bin/node      (env var override)
#   3. $OSD_HOME/node/bin/node  (bundled — removed here, so skipped)
#   4. $(command -v node)       (system node from base image) ✅
#
# Build arguments:
#   VERSION:                   Required. Used to label the image, e.g. '3.7.0'.
#   BUILD_DATE:                Required. RFC3339 UTC timestamp, e.g. '2026-08-12T08:00:00Z'.
#   NOTES:                     Optional. Pipeline notes string. Defaults to 'None'.
#   UID:                       Optional. opensearch-dashboards user id. Defaults to 1000.
#   GID:                       Optional. opensearch-dashboards group id. Defaults to 1000.
#   OPENSEARCH_DASHBOARDS_HOME: Optional. Installation root. Defaults to /usr/share/opensearch-dashboards.
#
# Prerequisites:
#   - docker login registry.access.redhat.com  (Red Hat account required to pull base image)
#   - docker buildx with multi-arch support (tonistiigi/binfmt installed for non-native arches)
#
# Build example (multi-arch, push to registry):
#   cd docker/release
#   ./build-image-multi-arch.sh \
#     -v 3.7.0 \
#     -p opensearch-dashboards \
#     -a x64,arm64 \
#     -f dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile \
#     -r icr.io/wxd_dev/opensearch-dashboards \
#     -t "../../tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-x64.tar.gz,\
# ../../tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-arm64.tar.gz"
#
# Build example (single arch, local only):
#   cd docker/release
#   ./build-image-single-arch.sh \
#     -v 3.7.0 \
#     -p opensearch-dashboards \
#     -a x64 \
#     -f dockerfiles/opensearch-dashboards.ubi9-nodejs-multiarch.dockerfile \
#     -t ../../tar/dist/opensearch-dashboards/opensearch-dashboards-3.7.0-linux-x64.tar.gz

FROM registry.access.redhat.com/ubi9/nodejs-22-minimal:9.8-1787020445@sha256:fc8e8ebdb189d074d6448db56baf78edb4f26e7017dcb1c235bf9420eb028cd1 AS ubi_base

ARG UID=1000
ARG GID=1000
ARG VERSION
ARG OPENSEARCH_DASHBOARDS_HOME=/usr/share/opensearch-dashboards

# nodejs-22-minimal sets a non-root default user; switch to root for package
# installation and user/group management, then drop back before the COPY.
USER root

# Install runtime deps + tools needed to unpack the tarball and manage users.
# nss, fontconfig, freetype: required by reportsDashboards (headless Chromium / PDF generation).
# shadow-utils: groupadd / adduser.  which: used by securityadmin.sh.
RUN microdnf -y install tar gzip shadow-utils which nss fontconfig freetype && \
    microdnf clean all

# Create opensearch-dashboards user and group
RUN groupadd -g $GID opensearch-dashboards && \
    adduser -u $UID -g $GID -d $OPENSEARCH_DASHBOARDS_HOME opensearch-dashboards

########################### Stage 0 — unpack and configure ########################
FROM ubi_base AS ubi_stage_0

ARG UID=1000
ARG GID=1000
ARG VERSION
ARG TEMP_DIR=/tmp/opensearch-dashboards
ARG OPENSEARCH_DASHBOARDS_HOME=/usr/share/opensearch-dashboards

USER root

# Create temp working directory
RUN mkdir $TEMP_DIR

# Copy the build context (tarball + config files) into the temp directory
COPY * $TEMP_DIR/

# Unpack tarball, remove bundled x64 Node.js binary, apply config files
# Removing node/ causes use_node to fall through to the arch-native system Node.
RUN tar -xzpf $TEMP_DIR/opensearch-dashboards-`uname -p`.tgz -C $OPENSEARCH_DASHBOARDS_HOME --strip-components=1 && \
    \
    # Remove the arch-specific bundled Node.js — system Node from base image is used instead
    rm -rf $OPENSEARCH_DASHBOARDS_HOME/node && \
    \
    MAJOR_VERSION_ENTRYPOINT=`echo $VERSION | cut -d. -f1` && \
    MAJOR_VERSION_YML=`echo $VERSION | cut -d. -f1` && \
    echo "Major version entrypoint: $MAJOR_VERSION_ENTRYPOINT" && \
    echo "Major version yml: $MAJOR_VERSION_YML" && \
    if ! (ls $TEMP_DIR | grep -E "opensearch-dashboards-docker-entrypoint-.*.x.sh" | grep $MAJOR_VERSION_ENTRYPOINT); then MAJOR_VERSION_ENTRYPOINT="default"; fi && \
    if ! (ls $TEMP_DIR | grep -E "opensearch_dashboards-.*.x.yml" | grep $MAJOR_VERSION_YML); then MAJOR_VERSION_YML="default"; fi && \
    cp -v $TEMP_DIR/opensearch-dashboards-docker-entrypoint-$MAJOR_VERSION_ENTRYPOINT.x.sh $OPENSEARCH_DASHBOARDS_HOME/opensearch-dashboards-docker-entrypoint.sh && \
    cp -v $TEMP_DIR/opensearch_dashboards-$MAJOR_VERSION_YML.x.yml $OPENSEARCH_DASHBOARDS_HOME/config/opensearch_dashboards.yml && \
    cp -v $TEMP_DIR/opensearch.example.org.* $OPENSEARCH_DASHBOARDS_HOME/config/ && \
    echo "server.host: '0.0.0.0'" >> $OPENSEARCH_DASHBOARDS_HOME/config/opensearch_dashboards.yml && \
    ls -l $OPENSEARCH_DASHBOARDS_HOME && \
    rm -rf $TEMP_DIR

########################### Stage 1 — final runtime image ########################
# Uses the arch-native nodejs-22-minimal image — Docker buildx selects the correct
# variant (amd64/arm64/ppc64le/s390x) automatically during multi-arch builds.
FROM ubi_base

ARG UID=1000
ARG GID=1000
ARG OPENSEARCH_DASHBOARDS_HOME=/usr/share/opensearch-dashboards

# Copy the unpacked (and node/-stripped) installation from stage 0
COPY --from=ubi_stage_0 --chown=$UID:$GID $OPENSEARCH_DASHBOARDS_HOME $OPENSEARCH_DASHBOARDS_HOME

# Setup working directory and PATH
WORKDIR $OPENSEARCH_DASHBOARDS_HOME
ENV PATH=$PATH:$OPENSEARCH_DASHBOARDS_HOME/bin

# Run as non-root
USER $UID

# Dashboards UI port
EXPOSE 5601

ARG VERSION
ARG BUILD_DATE
ARG NOTES

LABEL org.label-schema.schema-version="1.0" \
  org.label-schema.name="opensearch-dashboards" \
  org.label-schema.version="$VERSION" \
  org.label-schema.url="https://opensearch.org" \
  org.label-schema.vcs-url="https://github.com/opensearch-project/OpenSearch-Dashboards" \
  org.label-schema.license="Apache-2.0" \
  org.label-schema.vendor="OpenSearch" \
  org.label-schema.description="$NOTES" \
  org.label-schema.build-date="$BUILD_DATE"

ENTRYPOINT ["./opensearch-dashboards-docker-entrypoint.sh"]
CMD ["opensearch-dashboards"]
