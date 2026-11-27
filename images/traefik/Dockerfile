# Traefik with the CrowdSec bouncer plugin baked in (Traefik "local plugin" mode),
# so the proxy never needs to download the plugin from the Traefik plugin catalog at startup.
ARG TRAEFIK_VERSION=v3.8.0

FROM alpine/git:latest AS plugin
ARG BOUNCER_PLUGIN_VERSION=v1.8.2
# The plugin repository ships its vendor/ directory, which Traefik's interpreter needs.
RUN git clone --depth 1 --branch "${BOUNCER_PLUGIN_VERSION}" \
      https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin.git /src \
 && test -d /src/vendor \
 && rm -rf /src/.git

FROM traefik:${TRAEFIK_VERSION}
ARG BOUNCER_PLUGIN_VERSION=v1.8.2
LABEL org.opencontainers.image.title="crowdsec-waf-traefik" \
      org.opencontainers.image.description="Traefik with the CrowdSec bouncer plugin (AppSec/WAF) preinstalled" \
      io.crowdsec.bouncer-plugin.version="${BOUNCER_PLUGIN_VERSION}"

# Traefik resolves local plugins relative to its working directory: ./plugins-local/src/<moduleName>
COPY --from=plugin /src /plugins-local/src/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
WORKDIR /
