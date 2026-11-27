# CrowdSec WAF on Kubernetes


Traefik terminates TLS, asks CrowdSec AppSec (OWASP CRS, virtual patching and your custom rules) to
inspect each request, and forwards clean requests over TLS to a single REST or WebSocket upstream.

```
client --TLS--> Traefik + bouncer plugin --> AppSec pods (OWASP CRS) --> LAPI
                       | TLS (re-encrypted)
                 upstream service (REST / WebSocket)
```

| Path | Contents |
|---|---|
| `images/traefik` | Traefik with the CrowdSec bouncer plugin baked in |
| `images/crowdsec` | CrowdSec with the CRS and virtual patching collections preselected |
| `charts/crowdsec-waf` | Umbrella Helm chart (proxy + official `crowdsec` chart for LAPI and AppSec) |
| `examples/values-example.yaml` | Starting point for your own values |
| `docs/alloy.md` | Alloy config for logs (Loki) and metrics (Mimir) |

## 1. Prerequisites

- Kubernetes 1.25+ and `kubectl` access to the target cluster
- Helm 3.8+ (OCI support), Docker with buildx (only needed to build images)
- Access to the Harbor registry (`harbor.monitor.c8y.io`) and a robot account for pulling images
- A TLS certificate for the public hostname, as `tls.crt` and `tls.key`
- The cluster must be able to pull images from Harbor and reach `crowdsecurity.github.io` only at chart build time

## 2. Build and publish (once per version)

Defaults follow the other projects: `harbor.monitor.c8y.io/test1` for images and
`harbor.monitor.c8y.io/charts` for charts. Override with `repo=` and `helmrepo=`.

```sh
docker login harbor.monitor.c8y.io
helm registry login harbor.monitor.c8y.io

make help                 # list targets
make release version=0.1.0
```

`make release` lints the chart, pushes multi-arch images, and pushes the chart as an OCI artifact.
Upstream versions are pinned in `versions.env`; keep `CROWDSEC_VERSION` equal to the appVersion of the
`crowdsec` chart dependency (the subchart pulls the image by that tag).

## 3. Prepare the namespace

Deploy **one release per namespace**: the subchart mounts ConfigMaps and the bouncer Secret by fixed names.

```sh
kubectl create namespace waf

# Pull secret for Harbor (use your robot account)
kubectl -n waf create secret docker-registry harbor-pull \
  --docker-server=harbor.monitor.c8y.io --docker-username='<robot>' --docker-password='<token>'

# Incoming TLS certificate (kubernetes.io/tls)
kubectl -n waf create secret tls waf-frontend-tls --cert=tls.crt --key=tls.key

# CA that signed the upstream certificate (optional, otherwise the system trust store is used)
kubectl -n waf create secret generic upstream-ca --from-file=ca.crt=upstream-ca.pem
```

With cert-manager, create the `waf-frontend-tls` Secret through a `Certificate` instead.
After renewing a certificate Secret, restart the proxy (`kubectl -n waf rollout restart deploy/waf-crowdsec-waf-proxy`) so it is certain to load it; automatic reload of mounted certificates has not been verified.

## 4. Configure

```sh
cp examples/values-example.yaml my-values.yaml
```

Start from the example below (also in `examples/values-example.yaml`):

```yaml
# Example values for a REST/WebSocket API behind the WAF.
# Copy, adjust, and pass with: helm install waf <chart> -n waf -f my-values.yaml

# --- WAF behaviour -----------------------------------------------------------
waf:
  mode: detect            # detect = log and alert only; switch to "block" after reviewing alerts
  failOpen: false         # block mode: reject requests when AppSec is unreachable

# OWASP CRS tuning (restart the AppSec pods after changing)
crs:
  paranoiaLevel: 1        # 1-4, higher = more rules and more false positives
  anomalyScoreThreshold: 5
  disabledRuleIds: []     # e.g. [942100] to disable a rule that causes false positives

# --- Incoming TLS and routing ------------------------------------------------
tls:
  secretName: waf-frontend-tls       # kubernetes.io/tls Secret in the release namespace

route:
  rule: "Host(`api.example.com`)"

# --- Upstream (single backend, re-encrypted) ---------------------------------
upstream:
  host: my-api.my-namespace.svc.cluster.local
  port: 8443
  scheme: https
  caSecret:
    name: upstream-ca                # Secret with key ca.crt
    key: ca.crt
  # serverName: my-api.internal       # if the certificate name differs from host
  # clientCertSecret: upstream-client # kubernetes.io/tls Secret, for mTLS to the backend

# --- Proxy -------------------------------------------------------------------
proxy:
  replicas: 2
  trustedIPs: ["10.0.0.0/8"]         # source ranges of your load balancer / ingress
  service:
    type: LoadBalancer
  autoscaling:
    enabled: false
    minReplicas: 2
    maxReplicas: 10
  timeouts:
    shutdownGrace: 120s              # time WebSocket connections get to finish on rollout

# Prometheus Operator (leave off if Alloy scrapes pods directly, see docs/alloy.md)
metrics:
  podMonitor:
    enabled: false

# --- Registry pull secrets (Harbor) ------------------------------------------
imagePullSecrets: [{name: harbor-pull}]

# --- CrowdSec subchart (LAPI + AppSec) ---------------------------------------
crowdsec:
  image:
    pullSecrets: [{name: harbor-pull}]
  appsec:
    replicas: 2
    # Custom AppSec rules. The rule name must start with "custom/".
    rules:
      block-debug.yaml: |
        name: custom/block-debug
        description: "Block access to /debug"
        rules:
          - zones: [URI]
            transform: [lowercase]
            match: {type: startsWith, value: /debug}
        labels:
          type: exploit
          service: http
          behavior: "http:exploit"
          confidence: 3
          spoofable: 0
          label: "Debug endpoint access"
```

Minimum required: `tls.secretName` and `upstream.host`. Important settings:

| Value | Purpose |
|---|---|
| `waf.mode` | `detect` (default, log and alert only) or `block` |
| `waf.failOpen` | Block mode only: allow traffic when AppSec is unreachable |
| `route.rule` | Traefik router rule, e.g. ``Host(`api.example.com`)`` |
| `upstream.*` | Host, port, scheme, CA Secret, optional client certificate Secret for mTLS |
| `proxy.trustedIPs` | Source ranges of your load balancer. Without this the WAF sees the LB as the client |
| `proxy.replicas` / `proxy.autoscaling` | Proxy scaling |
| `crowdsec.appsec.replicas` | AppSec scaling |
| `crowdsec.appsec.rules` | Custom rules (rule `name` must start with `custom/`) |
| `crs.*` | CRS paranoia level, anomaly threshold, disabled rule IDs, extra SecLang |

### Configuring the upstream

The chart protects **one upstream** (a single backend address). Every request that matches `route.rule` and passes the WAF
is forwarded there; the connection from the proxy to the upstream is a separate hop from the client connection.

| Value | Default | Meaning |
|---|---|---|
| `upstream.host` | required | DNS name of the backend. For a Kubernetes Service use `<service>.<namespace>.svc.cluster.local` |
| `upstream.port` | `443` | Port of the Service (not the pod's target port) |
| `upstream.scheme` | `https` | `https` re-encrypts to the backend, `http` sends plain text |
| `upstream.serverName` | `upstream.host` | Name used for SNI and certificate verification. Set it when the certificate name differs from `host` |
| `upstream.caSecret.name` / `.key` | empty / `ca.crt` | Secret holding the CA that signed the backend certificate. Empty means the system trust store is used |
| `upstream.clientCertSecret` | empty | `kubernetes.io/tls` Secret with a client certificate, for backends that require mTLS |
| `upstream.insecureSkipVerify` | `false` | Skip certificate verification. For testing only |
| `route.rule` | ``PathPrefix(`/`)`` | Which requests are routed to the upstream, e.g. ``Host(`api.example.com`)`` |

**Backend in the same cluster, HTTPS with a private CA** (the usual case):

```sh
kubectl -n waf create secret generic upstream-ca --from-file=ca.crt=upstream-ca.pem
```

```yaml
upstream:
  host: my-api.my-namespace.svc.cluster.local
  port: 8443
  scheme: https
  caSecret: {name: upstream-ca, key: ca.crt}
```

The backend certificate must contain `host` (or `serverName`) as a DNS SAN. If it only has a name such as `my-api.internal`,
keep `host` as the Service name and set `serverName: my-api.internal`.

**Backend with a publicly trusted certificate** (for example an external API): omit `caSecret`, and set `host` to its public name.
The cluster must be able to resolve it and reach it.

**Backend that requires mTLS:**

```sh
kubectl -n waf create secret tls upstream-client --cert=client.crt --key=client.key
```

```yaml
upstream:
  clientCertSecret: upstream-client
```

**Plain HTTP backend** (for example inside a mesh that already encrypts traffic): `scheme: http` and the Service port, e.g. `port: 8080`.
`caSecret`, `serverName` and `clientCertSecret` are ignored.

**Notes**

- The `Host` header of the client request is passed to the backend unchanged. If the backend expects a different host name,
  that needs a header rewrite, which the chart doesn't provide yet.
- Backends in other namespaces work with the full Service name. Secrets (`upstream-ca`, `upstream-client`) must be in the
  release namespace.
- The WAF does not load-balance across different backends. To protect several services, install one release per namespace,
  or put them behind one Service. Traffic to a multi-replica Service is balanced by Kubernetes, not Traefik.
- After changing certificate Secrets (including the upstream CA or client certificate), restart the proxy. After changing `upstream.*` values,
  run `helm upgrade`; the proxy pods restart on their own.

**Check the connection** from inside the cluster, before debugging the WAF:

```sh
kubectl -n waf run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -v --cacert /dev/null -k https://my-api.my-namespace.svc.cluster.local:8443/
```

If this works but requests through the proxy return `502` or `503`, check `kubectl -n waf logs deploy/waf-crowdsec-waf-proxy`
for the TLS error, most often `x509: certificate is valid for ...` (wrong `serverName`) or `unknown authority` (missing or wrong CA).

## 5. Install

```sh
helm install waf oci://harbor.monitor.c8y.io/charts/crowdsec-waf --version 0.1.0 \
  -n waf -f my-values.yaml
kubectl -n waf get pods -w
```

Expected pods: `waf-crowdsec-waf-proxy-*`, `waf-appsec-*`, `waf-lapi-*`. The proxy becomes ready once its
config and certificates are mounted; AppSec registers itself with the LAPI on first start (allow a minute).

Find the address of the proxy:

```sh
kubectl -n waf get svc waf-crowdsec-waf-proxy
```

Point your DNS name at the LoadBalancer address, or expose the ClusterIP service through your existing ingress.
If the cluster has no LoadBalancer, use `kubectl -n waf port-forward svc/waf-crowdsec-waf-proxy 8443:443` for a test.

## 6. Verify

```sh
HOST=api.example.com   # or localhost:8443 with port-forward and curl -k

# Clean request: reaches the upstream
curl -i https://$HOST/

# Attack patterns (SQL injection, path traversal)
curl -i "https://$HOST/?id=1%27%20OR%20%271%27=%271"
curl -i "https://$HOST/../../etc/passwd" --path-as-is

# Detect mode: both pass through, but alerts are recorded
kubectl -n waf exec deploy/waf-lapi -- cscli alerts list
kubectl -n waf logs deploy/waf-appsec | tail
```

In `block` mode the attack requests return `403`.

## 7. Roll out to blocking

1. Run in `detect` mode and watch alerts for a few days with real traffic.
2. Fix false positives with `crs.disabledRuleIds`, `crs.extraSecLang` or by raising `crs.anomalyScoreThreshold`.
3. Switch:

   ```sh
   helm upgrade waf oci://harbor.monitor.c8y.io/charts/crowdsec-waf --version 0.1.0 \
     -n waf -f my-values.yaml --set waf.mode=block
   kubectl -n waf rollout restart deploy/waf-appsec
   ```

Changes to custom rules or CRS tuning also need `kubectl -n waf rollout restart deploy/waf-appsec`.

## WebSocket support

WebSocket upgrades (`Connection: Upgrade`, `Upgrade: websocket`) pass through Traefik to the upstream, including
the re-encrypted hop, with no extra configuration. Things to know:

- **Only the handshake is inspected.** The WAF checks the HTTP upgrade request (path, headers, query, cookies). WebSocket frames
  after the upgrade are not inspected.
- **Timeouts.** `proxy.timeouts.write` is `0s` (unlimited) so streams are not cut. Hijacked WebSocket connections are not
  subject to `idle`. If connections drop at a regular interval, a load balancer in front is the usual cause: raise its idle timeout
  (for example `service.beta.kubernetes.io/aws-load-balancer-...` or Azure/GCP equivalents via `proxy.service.annotations`) or send
  application-level ping frames.
- **Rollouts.** On shutdown the proxy stops accepting new requests and gives open connections `proxy.timeouts.shutdownGrace`
  (default 60s) to finish; `terminationGracePeriodSeconds` follows automatically. Clients should reconnect.
- **Scaling.** Connections stay on the pod that accepted them. Scale-down closes the connections of removed pods.
- **Test it:**

  ```sh
  websocat wss://$HOST/ws          # or: npx wscat -c wss://$HOST/ws
  ```

  In detect mode, check `kubectl -n waf logs deploy/waf-crowdsec-waf-proxy` for a `101` status on the access log line.

This has not been verified against a live cluster yet: run the test above before relying on it, and confirm the bouncer plugin
does not interfere with the upgrade in your environment.

## Operations

**Upgrade**

```sh
helm upgrade waf oci://harbor.monitor.c8y.io/charts/crowdsec-waf --version <new> -n waf -f my-values.yaml
```

**Scale**: set `proxy.replicas` (or `proxy.autoscaling.enabled=true`) and `crowdsec.appsec.replicas`. The LAPI runs as a single
replica with SQLite. For a replicated LAPI, configure an external database through the `crowdsec` chart values.

**Secrets**: the bouncer API key is generated into Secret `crowdsec-waf-secrets` and registered in the LAPI on startup, and is kept
across upgrades. To manage it yourself (External Secrets, Sealed Secrets) set `secrets.create=false` and provide a Secret with the
same name and key.

**Logs and metrics**: JSON access logs go to stdout, Prometheus metrics are on `:9100` (proxy) and `:6060` (CrowdSec). See
`docs/alloy.md` for Alloy shipping logs to Loki and metrics to Mimir. With the Prometheus Operator use
`metrics.serviceMonitor.enabled` or `metrics.podMonitor.enabled`.

**Uninstall**

```sh
helm uninstall waf -n waf
kubectl delete namespace waf   # also removes the Secrets created above
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `helm install` fails with `tls.secretName is required` | Set `tls.secretName` and `upstream.host` |
| Proxy pod stuck in `ContainerCreating` | A referenced Secret is missing: `kubectl -n waf describe pod` |
| `ImagePullBackOff` | `imagePullSecrets` and `crowdsec.image.pullSecrets` both need the Harbor secret |
| AppSec pod waits for LAPI | `kubectl -n waf logs deploy/waf-lapi`, then restart AppSec |
| Everything allowed in block mode | `kubectl -n waf rollout restart deploy/waf-appsec`; confirm `waf.mode=block` was applied: `helm get values waf -n waf` |
| All requests blocked with 403 or 5xx | AppSec unreachable with `waf.failOpen=false`: `kubectl -n waf get pods`. Set `waf.mode=detect` to stop blocking |
| Client IP in logs is the load balancer | Set `proxy.trustedIPs` to the LB ranges and use `externalTrafficPolicy: Local` or proxy protocol |
| Legitimate request blocked | `kubectl -n waf logs deploy/waf-appsec` shows the CRS rule ID; exclude it with `crs.disabledRuleIds` or `crs.extraSecLang` |

## Testing on kind

```sh
make test          # needs docker, kind, kubectl, helm, curl, openssl
KEEP=1 make test   # keep the cluster afterwards for debugging
make test-clean    # delete the kind cluster
```

`make test` builds both images locally (`local/...:e2e`), creates a kind cluster, deploys an echo backend and the chart
in detect mode, then checks: clean requests pass, SQL injection, path traversal and a custom `/debug` rule are allowed but
raise alerts, and a WebSocket upgrade returns `101`. It then upgrades to block mode and checks that the attacks and the custom
rule return `403` while clean requests and the WebSocket upgrade still succeed. On failure it prints proxy and AppSec logs.
The backend is plain HTTP, so TLS to the upstream (`upstream.scheme=https`) is not covered.
