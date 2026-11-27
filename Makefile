# Build and publish the CrowdSec WAF images and Helm chart to Harbor.
# Conventions follow the other projects: images and charts go to separate Harbor projects.
#
#   make build          build both images locally (current platform)
#   make push           build multi-arch images and push them to Harbor
#   make helm-push      package the chart and push it as OCI artifact
#   make release        lint, push images, push chart
#
# Log in first:  docker login harbor.monitor.c8y.io ;  helm registry login harbor.monitor.c8y.io

-include versions.env
export

version   ?= 0.1.0
repo      ?= harbor.monitor.c8y.io/test1
helmrepo  ?= harbor.monitor.c8y.io/charts
PLATFORMS ?= linux/amd64,linux/arm64

CHART_DIR       := charts/crowdsec-waf
CHART_NAME      := crowdsec-waf
IMG_TRAEFIK     := $(repo)/crowdsec-waf-traefik
IMG_CROWDSEC    := $(repo)/crowdsec-waf-crowdsec
BUILD_ARGS_T    := --build-arg TRAEFIK_VERSION=$(TRAEFIK_VERSION) --build-arg BOUNCER_PLUGIN_VERSION=$(BOUNCER_PLUGIN_VERSION)
BUILD_ARGS_C    := --build-arg CROWDSEC_VERSION=$(CROWDSEC_VERSION)

.DEFAULT_GOAL := help
.PHONY: help build build-traefik build-crowdsec push push-traefik push-crowdsec \
        helm-deps helm-lint helm-template helm-package helm-push release test test-clean clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'
	@echo; echo "  version=$(version) repo=$(repo) helmrepo=$(helmrepo)"

build: build-traefik build-crowdsec ## Build both images locally

build-traefik: ## Build the Traefik + bouncer plugin image
	docker build $(BUILD_ARGS_T) -t $(IMG_TRAEFIK):$(version) images/traefik

build-crowdsec: ## Build the CrowdSec image
	docker build $(BUILD_ARGS_C) -t $(IMG_CROWDSEC):$(version) -t $(IMG_CROWDSEC):$(CROWDSEC_VERSION) images/crowdsec

push: push-traefik push-crowdsec ## Build multi-arch images and push to Harbor

push-traefik:
	docker buildx build --platform $(PLATFORMS) $(BUILD_ARGS_T) -t $(IMG_TRAEFIK):$(version) --push images/traefik

push-crowdsec:
	docker buildx build --platform $(PLATFORMS) $(BUILD_ARGS_C) -t $(IMG_CROWDSEC):$(version) -t $(IMG_CROWDSEC):$(CROWDSEC_VERSION) --push images/crowdsec

helm-deps: ## Fetch chart dependencies (official crowdsec chart)
	helm dependency update $(CHART_DIR)

helm-lint: helm-deps ## Lint the chart in detect and block mode
	helm lint $(CHART_DIR) -f $(CHART_DIR)/ci/test-values.yaml
	helm lint $(CHART_DIR) -f $(CHART_DIR)/ci/test-values.yaml --set waf.mode=block

helm-template: helm-deps ## Render the chart (smoke test)
	helm template test $(CHART_DIR) -f $(CHART_DIR)/ci/test-values.yaml > /dev/null
	helm template test $(CHART_DIR) -f $(CHART_DIR)/ci/test-values.yaml --set waf.mode=block > /dev/null

helm-package: helm-deps ## Package the chart into dist/
	mkdir -p dist
	helm package $(CHART_DIR) --version $(version) --app-version $(version) --destination dist

helm-push: helm-package ## Push the packaged chart to Harbor (OCI)
	helm push dist/$(CHART_NAME)-$(version).tgz oci://$(helmrepo)

release: helm-lint helm-template push helm-push ## Lint, push images, push chart

clean: ## Remove build output
	rm -rf dist $(CHART_DIR)/charts $(CHART_DIR)/Chart.lock

KIND_CLUSTER ?= crowdsec-waf-e2e

test: helm-deps ## End-to-end test on kind (builds local images, detect then block mode)
	$(MAKE) build repo=local version=e2e
	CLUSTER=$(KIND_CLUSTER) TAG=e2e IMG_TRAEFIK=local/crowdsec-waf-traefik IMG_CROWDSEC=local/crowdsec-waf-crowdsec \
	  ./scripts/e2e.sh

test-clean: ## Delete the kind test cluster
	kind delete cluster --name $(KIND_CLUSTER)
