# syntax=docker/dockerfile:1
# Worker image: the bridge runs the root entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.1

# Exact firebase-tools version (reproducible builds); keep in sync with
# FIREBASE_CLI_VERSION in mobile-store/values.yaml.
ARG FIREBASE_CLI_VERSION=14.27.0

# Distribution tooling (Alpine base):
#   aws-cli   download the build assets (s3) and read the secrets (secretsmanager)
#   unzip     validate the APK/IPA archives
#   nodejs    runtime of firebase-tools (Firebase App Distribution CLI); npm only at build time
#   openssl   sign the JWT that firebase_access_token exchanges for a Google token (no gcloud)
#   curl      https assets and the Firebase REST API
# The keyvault signing layer also needs apksigner (Android build-tools), which
# is NOT installed here: the SDK is large and its license must be accepted.
# Scopes that sign with keyvault build a derived image that adds the
# build-tools and pin it in the agent (decided in a later phase).
USER root
# npm is only needed to install firebase-tools: it is removed afterwards
# (firebase runs on nodejs alone). firebase-tools 14 needs Node.js >= 20: the
# build fails before installing it when the base image's nodejs is older, and
# fails at the end when the installed CLI does not start. The check runs with a
# throwaway HOME: firebase writes ~/.config/configstore on start, and a root-owned
# copy in the runtime user's HOME breaks every later firebase call (EACCES).
RUN apk add --no-cache aws-cli nodejs npm openssl curl unzip \
    && node --version \
    && node -e 'const v = process.versions.node; if (Number(v.split(".")[0]) < 20) { console.error("firebase-tools needs Node.js >= 20, the image has " + v); process.exit(1); }' \
    && npm install -g "firebase-tools@${FIREBASE_CLI_VERSION}" \
    && npm cache clean --force \
    && apk del --no-cache npm \
    && rm -rf /root/.npm \
    && HOME=/tmp/firebase-version-check firebase --version \
    && rm -rf /tmp/firebase-version-check

# --chown: np chmods the action script in place, so the tree must belong to the runtime uid.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=mobile-store \
    NP_SERVICE_PATH=/app/pkg/mobile-store \
    NP_SCOPE_ENTRYPOINT=/app/pkg/entrypoint

# Numeric so runAsNonRoot admission can verify it; worker-bridge 2.0.0+ ships this user and a writable HOME.
USER 10001:10001
