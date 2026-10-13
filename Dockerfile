# syntax=docker/dockerfile:1
# Worker image: the bridge runs the root entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.1

# firebase-tools major version; keep in sync with FIREBASE_CLI_VERSION in mobile-store/values.yaml.
ARG FIREBASE_CLI_VERSION=14

# Distribution tooling (Alpine base):
#   aws-cli   download the build assets (s3) and read the secrets (secretsmanager)
#   unzip     validate the APK/IPA archives
#   nodejs    firebase-tools (Firebase App Distribution CLI)
#   openssl   sign the JWT that firebase_access_token exchanges for a Google token (no gcloud)
#   curl      https assets and the Firebase REST API
# The keyvault signing layer also needs apksigner (Android build-tools), which
# is NOT installed here: the SDK is large and its license must be accepted.
# Scopes that sign with keyvault build a derived image that adds the
# build-tools and pin it in the agent (decided in a later phase).
USER root
RUN apk add --no-cache aws-cli nodejs npm openssl curl unzip \
    && npm install -g "firebase-tools@${FIREBASE_CLI_VERSION}" \
    && npm cache clean --force

# --chown: np chmods the action script in place, so the tree must belong to the runtime uid.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=mobile-store \
    NP_SERVICE_PATH=/app/pkg/mobile-store \
    NP_SCOPE_ENTRYPOINT=/app/pkg/entrypoint

# Numeric so runAsNonRoot admission can verify it; worker-bridge 2.0.0+ ships this user and a writable HOME.
USER 10001:10001
