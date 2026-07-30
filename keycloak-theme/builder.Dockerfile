# Toolchain-only image for building the velobits Keycloakify theme jar.
# The theme source is bind-mounted at runtime (keycloak-theme-builder service
# in docker-compose.yml), so editing the theme never requires rebuilding this
# image — only the toolchain lives here.
#
# Matches the CI theme-build job: Node 22 + JDK + Maven (keycloakify build
# shells out to Maven for jar packaging; the jar is resources-only, so the
# Debian JDK 17 vs CI's temurin 21 difference doesn't affect the artifact).
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends maven openjdk-17-jdk-headless \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
