# Platform monorepo entrypoints. `make validate` is the contract (R10):
# byte-for-byte the same script locally and in CI.

.PHONY: validate validate-full render clean help

validate: ## Diff-scoped validation: helm template + kubeconform + kyverno test
	bash scripts/validate.sh

validate-full: ## Full-repo validation (nightly CI job)
	FULL=1 bash scripts/validate.sh

render: ## Render all charts with their CI values into build/rendered/ (no schema/policy checks)
	FULL=1 RENDER_ONLY=1 RENDER_DIFF=0 bash scripts/validate.sh

clean:
	rm -rf build/

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "%-16s %s\n", $$1, $$2}'
