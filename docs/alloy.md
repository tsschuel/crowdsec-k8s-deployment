# Alloy: logs to Loki, metrics to Mimir

Pods carry `app.kubernetes.io/component` labels: `waf-proxy` (Traefik access and plugin logs),
plus the CrowdSec subchart pods (`type: appsec`, LAPI). WAF matches show up in the AppSec pod logs and
as alerts in the LAPI.

```alloy
// Logs: proxy + CrowdSec pods -> Loki
discovery.kubernetes "pods" { role = "pod" }

discovery.relabel "waf" {
  targets = discovery.kubernetes.pods.targets
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    regex         = "waf"            // namespace of the release
    action        = "keep"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_component"]
    target_label  = "component"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_type"]
    target_label  = "crowdsec_type"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
}

loki.source.kubernetes "waf" {
  targets    = discovery.relabel.waf.output
  forward_to = [loki.process.waf.receiver]
}

loki.process "waf" {
  // Traefik access logs are JSON (proxy.accessLog.format=json).
  stage.match {
    selector = "{component=\"waf-proxy\"}"
    stage.json {
      expressions = { status = "DownstreamStatus", router = "RouterName" }
    }
    stage.labels { values = { status = "", router = "" } }
  }
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint { url = "https://loki.example.com/loki/api/v1/push" }
}

// Metrics: Traefik (:9100) and CrowdSec (:6060) -> Mimir
prometheus.scrape "waf_proxy" {
  targets    = discovery.relabel.waf_metrics.output
  forward_to = [prometheus.remote_write.mimir.receiver]
}

discovery.relabel "waf_metrics" {
  targets = discovery.kubernetes.pods.targets
  rule {
    source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_container_port_number"]
    regex         = "waf;(9100|6060)"
    action        = "keep"
  }
}

prometheus.remote_write "mimir" {
  endpoint { url = "https://mimir.example.com/api/v1/push" }
}
```

If you run the Prometheus Operator instead, set `metrics.serviceMonitor.enabled` or
`metrics.podMonitor.enabled`, and `crowdsec.appsec.metrics.serviceMonitor.enabled` for AppSec.
