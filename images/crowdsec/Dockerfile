# CrowdSec image used for LAPI and AppSec pods.
# The upstream (non-slim) image already ships a Hub snapshot, so the collections below are
# installed by the entrypoint from local content, without reaching the Hub at startup.
# The pinned image tag therefore pins the OWASP CRS version as well.
ARG CROWDSEC_VERSION=v1.8.2
FROM crowdsecurity/crowdsec:${CROWDSEC_VERSION}

LABEL org.opencontainers.image.title="crowdsec-waf-crowdsec" \
      org.opencontainers.image.description="CrowdSec with OWASP CRS (in-band) and virtual patching AppSec collections preselected"

# Blocking-capable CRS (crs-inband) and virtual patching. Whether requests are actually blocked
# is decided by the chart (waf.mode), not by the rule set.
ENV COLLECTIONS="crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-crs-inband"
