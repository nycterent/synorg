# Platform monorepo entrypoints. `make validate` is the contract (R10):
# byte-for-byte the same script locally and in CI.

.PHONY: validate validate-full render clean help integration integration-down

validate: ## Diff-scoped validation: helm template + kubeconform + kyverno test
	bash scripts/validate.sh

validate-full: ## Full-repo validation (nightly CI job)
	FULL=1 bash scripts/validate.sh

render: ## Render all charts with their CI values into build/rendered/ (no schema/policy checks)
	FULL=1 RENDER_ONLY=1 RENDER_DIFF=0 bash scripts/validate.sh

demo: ## Narrated read-only walkthrough (render + policy accept/deny + bridge)
	bash scripts/demo.sh

integration: ## Integration ladder: kind up -> tests/integration/*/ -> kind down
	bash tests/kind/up.sh
	@rc=0; \
	for t in $$(find tests/integration -mindepth 2 -name '*.sh' -type f 2>/dev/null | sort); do \
		echo "== $$t"; \
		bash "$$t" || { rc=1; break; }; \
	done; \
	if [ $$rc -ne 0 ]; then \
		echo "integration FAILED — cluster left up for debugging (make integration-down to remove)"; \
		exit 1; \
	fi
	bash tests/kind/down.sh

integration-down: ## Delete the kind integration cluster (idempotent)
	bash tests/kind/down.sh

# --- Docs site (Material for MkDocs, Diátaxis nav) --------------------------
DOCS_VENV := .venv-docs
$(DOCS_VENV): docs/requirements.txt
	python3 -m venv $(DOCS_VENV)
	$(DOCS_VENV)/bin/pip install --quiet --upgrade pip
	$(DOCS_VENV)/bin/pip install --quiet -r docs/requirements.txt

docs-serve: $(DOCS_VENV) ## Live-preview the docs at http://127.0.0.1:8000
	$(DOCS_VENV)/bin/mkdocs serve

docs-build: $(DOCS_VENV) ## Build the static HTML docs into site/
	$(DOCS_VENV)/bin/mkdocs build --strict

diagrams: ## Compile diagrams/*.tex (TikZ) to committed SVGs (needs tectonic + poppler)
	bash scripts/build-diagrams.sh

clean:
	rm -rf build/

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "%-16s %s\n", $$1, $$2}'
