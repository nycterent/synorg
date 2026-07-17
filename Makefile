# Platform monorepo entrypoints. `make validate` is the contract (R10):
# byte-for-byte the same script locally and in CI.

.PHONY: validate validate-full render clean help

validate: ## Diff-scoped validation: helm template + kubeconform + kyverno test
	bash scripts/validate.sh

validate-full: ## Full-repo validation (nightly CI job)
	FULL=1 bash scripts/validate.sh

render: ## Render all charts with their CI values into build/rendered/ (no schema/policy checks)
	FULL=1 RENDER_ONLY=1 RENDER_DIFF=0 bash scripts/validate.sh

demo: ## Narrated read-only walkthrough (render + policy accept/deny + bridge)
	bash scripts/demo.sh

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
