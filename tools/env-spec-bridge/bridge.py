#!/usr/bin/env python3
"""env-spec -> golden-service values bridge (U13, R4).

Translates a legacy env-spec (the ECS-era deploy DSL) into golden-service Helm
values, mechanically and deterministically: same input always yields the same
output, with zero interaction (Success Criterion 5). The bridge is a temporary
strangler artifact — each service is translated once, reviewed, then owned as
values; the tool retires when the last consumer converts (see README.md and
docs/env-spec-retirement.md).

Bridge semantics (R4):
  - Only keys in the env-spec contract are translated. Any other top-level key
    is a hard error naming the key (R10) — the bridge never silently drops
    input. Known ECS-isms that have no golden-chart home get a tailored message
    telling the migrator where the concept went (e.g. env vars -> ESO).
  - The golden-service values schema (charts/golden-service/values.schema.json)
    is the real validator: run `helm template` on the output to confirm.

Usage:
    python3 bridge.py <envspec.yaml>            # print values to stdout
    python3 bridge.py <envspec.yaml> -o out.yaml
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

import yaml


class BridgeError(Exception):
    """A translation failure. The message always names the offending key or
    field so an agent or human can self-correct in one pass (R10)."""


# Top-level env-spec keys the bridge understands and translates.
KNOWN_KEYS = {
    "service",
    "team",
    "class",
    "image",
    "cpu",
    "memory",
    "cpu_limit",
    "memory_limit",
    "port",
    "replicas",
    "gpu",
    "customer_data",
    "healthcheck",
    "readiness",
    "autoscale",
    "disruption_budget",
}

# ECS-isms with no golden-chart equivalent. Erroring here (rather than in the
# generic branch) lets us point the migrator at where the concept actually
# lives on the platform, instead of just "unknown key".
RETIRED_KEYS = {
    "env": (
        "environment variables are not a golden-chart value; the chart has no "
        "env surface by design. Project config via an ESO-managed "
        "ConfigMap/Secret (see docs/agent-interface.md) instead of inlining it"
    ),
    "secrets": (
        "inline secrets are denied at admission (never tier); reference an "
        "ESO-projected Secret from a namespace-local SecretStore"
    ),
    "network_mode": (
        "ECS network_mode has no golden-chart equivalent; EKS pod networking is "
        "cluster-default"
    ),
    "task_role_arn": (
        "ECS task IAM roles migrate to IRSA / Pod Identity bound to the "
        "workload ServiceAccount, not env-spec"
    ),
    "launch_type": (
        "ECS launch_type is meaningless on EKS; scheduling is derived from "
        "workloadClass and gpu"
    ),
}

REQUIRED_KEYS = ("service", "team", "class", "image", "cpu", "memory")

VALID_CLASSES = ("web", "inference")

DEFAULT_PORT = 8080

# Allowed sub-keys for the structured env-spec blocks. Unknown sub-keys error
# with a dotted name (e.g. "healthcheck.grace_period") — no silent drops at any
# nesting level.
SUBKEYS = {
    "healthcheck": {"path", "port"},
    "readiness": {"path", "port"},
    "autoscale": {"min", "max", "cpu_target"},
    "disruption_budget": {"min_available"},
}

# Sub-keys a structured block cannot omit: translate() dereferences them
# directly, so a partial block (e.g. autoscale without min/max) must fail with a
# named BridgeError rather than a raw KeyError.
REQUIRED_SUBKEYS = {
    "autoscale": frozenset({"min", "max", "cpu_target"}),
    "disruption_budget": frozenset({"min_available"}),
}

DEFAULT_LIVENESS_PATH = "/healthz"
DEFAULT_READINESS_PATH = "/readyz"

# Kubernetes resource.Quantity grammar: a signed number with an optional binary
# (Ki..Ei), decimal (m,k,M..E), or exponent suffix. Used to reject malformed
# cpu/memory strings; bare YAML numbers are rejected before this even runs.
_QUANTITY_RE = re.compile(
    r"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+|m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$"
)


def load(path: str | Path) -> dict[str, Any]:
    """Parse an env-spec YAML file into a dict. Raises BridgeError if the file
    cannot be read, is not valid YAML, or is not a YAML mapping — a broken input
    file is a named translation failure (R10), never a raw traceback."""
    try:
        text = Path(path).read_text()
    except OSError as err:
        raise BridgeError(f"cannot read env-spec file {str(path)!r}: {err}") from err
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as err:
        raise BridgeError(f"env-spec {str(path)!r} is not valid YAML: {err}") from err
    if not isinstance(data, dict):
        raise BridgeError(f"env-spec must be a YAML mapping, got {type(data).__name__}")
    return data


def dump(values: dict[str, Any]) -> str:
    """Serialize golden-service values deterministically. Insertion order is
    preserved (sort_keys=False) so output is stable across runs."""
    return yaml.safe_dump(values, sort_keys=False, default_flow_style=False)


def _reject_unknown(spec: dict[str, Any]) -> None:
    for key in spec:
        if key in RETIRED_KEYS:
            raise BridgeError(f"env-spec key '{key}': {RETIRED_KEYS[key]}")
        if key not in KNOWN_KEYS:
            raise BridgeError(
                f"unknown env-spec key '{key}' (not part of the env-spec contract)"
            )


def _validate_blocks(spec: dict[str, Any]) -> None:
    """Every structured block that is present must be a mapping carrying only
    known sub-keys and all required ones. Without this a scalar block
    (`healthcheck: /healthz`) or a partial one (`autoscale` without min/max)
    would surface as a raw AttributeError/KeyError instead of a BridgeError
    naming the dotted field (R10)."""
    for block, allowed in SUBKEYS.items():
        if block not in spec:
            continue
        value = spec[block]
        if not isinstance(value, dict):
            raise BridgeError(
                f"env-spec '{block}' must be a mapping of "
                f"{{{', '.join(sorted(allowed))}}}, got {type(value).__name__}"
            )
        for sub in value:
            if sub not in allowed:
                raise BridgeError(
                    f"unknown env-spec key '{block}.{sub}' "
                    f"(allowed: {', '.join(sorted(allowed))})"
                )
        for sub in sorted(REQUIRED_SUBKEYS.get(block, frozenset())):
            if sub not in value:
                raise BridgeError(
                    f"env-spec '{block}' missing required sub-key '{block}.{sub}'"
                )


def _require(spec: dict[str, Any]) -> None:
    for key in REQUIRED_KEYS:
        value = spec.get(key)
        if value is None or (isinstance(value, str) and value == ""):
            raise BridgeError(f"missing required env-spec key '{key}'")


def _int(value: Any, key: str) -> int:
    """Coerce an env-spec numeric field to int, rejecting anything that is not
    already an integer. Floats are rejected outright (never truncated) and bools
    — int subclasses in Python — are rejected too, so `replicas: 2.5` or
    `port: "eighty"` is a BridgeError naming the key, not a silent 2 or a raw
    ValueError (R10)."""
    if isinstance(value, bool) or not isinstance(value, int):
        raise BridgeError(f"env-spec '{key}' must be an integer, got {value!r}")
    return value


def _quantity(value: Any, key: str) -> str:
    """Validate a Kubernetes resource quantity, requiring the explicit string
    form. A bare YAML number (`cpu: 1024`) is rejected: ECS cpu/memory numbers do
    not map 1:1 to k8s quantities (1024 would become 1024 cores, not 1 vCPU), so
    silently stringifying it ships the wrong request. The migrator must write the
    quantity explicitly, e.g. "1" or "8Gi" (R10)."""
    if isinstance(value, bool) or not isinstance(value, str):
        raise BridgeError(
            f"env-spec '{key}' must be a quoted Kubernetes quantity string "
            f'(e.g. "2", "500m", "8Gi"), not a bare number — a bare ECS '
            f"cpu/memory value maps to the wrong k8s quantity. Got {value!r}"
        )
    if not _QUANTITY_RE.match(value):
        raise BridgeError(
            f"env-spec '{key}'={value!r} is not a valid Kubernetes quantity "
            f'(expected e.g. "2", "500m", "8Gi")'
        )
    return value


def _split_image(image: str) -> dict[str, str]:
    if not isinstance(image, str) or ":" not in image:
        raise BridgeError(f"image must be 'repository:tag', got {image!r}")
    repository, tag = image.rsplit(":", 1)
    if not repository or not tag or "/" in tag:
        raise BridgeError(f"image must be 'repository:tag', got {image!r}")
    return {"repository": repository, "tag": tag}


def _probe(
    block: dict[str, Any] | None, default_path: str, port: int, name: str
) -> dict[str, Any]:
    block = block or {}
    return {
        "path": block.get("path", default_path),
        "port": _int(block.get("port", port), f"{name}.port"),
    }


def translate(spec: dict[str, Any]) -> dict[str, Any]:
    """Translate a parsed env-spec into golden-service values.

    Deterministic and side-effect free. Output key order is fixed to match the
    schema's own ordering so golden files stay stable."""
    _reject_unknown(spec)
    _require(spec)
    _validate_blocks(spec)

    workload_class = spec["class"]
    if workload_class not in VALID_CLASSES:
        raise BridgeError(
            f"env-spec 'class' must be one of {VALID_CLASSES}, got {workload_class!r}"
        )

    port = _int(spec.get("port", DEFAULT_PORT), "port")

    values: dict[str, Any] = {
        "team": spec["team"],
        "workloadClass": workload_class,
    }

    # customerData: emit only when set true; chart default is false.
    if spec.get("customer_data"):
        values["customerData"] = True

    if "replicas" in spec:
        values["replicas"] = _int(spec["replicas"], "replicas")

    # gpu: emit only when >0; the schema default is 0 (no GPU scheduling).
    gpu = _int(spec.get("gpu", 0), "gpu")
    if gpu > 0:
        values["gpu"] = gpu

    values["port"] = port
    values["image"] = _split_image(spec["image"])

    # Resources: requests are always required; limits emitted only for the
    # fields the env-spec pins, so the chart's limit defaults fill the rest.
    # cpu/memory must be explicit quantity strings — a bare number is rejected.
    requests = {
        "cpu": _quantity(spec["cpu"], "cpu"),
        "memory": _quantity(spec["memory"], "memory"),
    }
    resources: dict[str, Any] = {"requests": requests}
    limits: dict[str, Any] = {}
    if "cpu_limit" in spec:
        limits["cpu"] = _quantity(spec["cpu_limit"], "cpu_limit")
    if "memory_limit" in spec:
        limits["memory"] = _quantity(spec["memory_limit"], "memory_limit")
    if limits:
        resources["limits"] = limits
    values["resources"] = resources

    # Service: targetPort tracks the container port so ALB/Service forwarding
    # is correct even when the workload does not listen on the chart default.
    values["service"] = {"type": "ClusterIP", "port": 80, "targetPort": port}

    # Probes: always fully specified so they hit the container port, never the
    # chart's 8080 default when the workload listens elsewhere.
    values["probes"] = {
        "liveness": _probe(
            spec.get("healthcheck"), DEFAULT_LIVENESS_PATH, port, "healthcheck"
        ),
        "readiness": _probe(
            spec.get("readiness"), DEFAULT_READINESS_PATH, port, "readiness"
        ),
    }

    if "autoscale" in spec:
        auto = spec["autoscale"]
        values["hpa"] = {
            "enabled": True,
            "minReplicas": _int(auto["min"], "autoscale.min"),
            "maxReplicas": _int(auto["max"], "autoscale.max"),
            "targetCPUUtilizationPercentage": _int(
                auto["cpu_target"], "autoscale.cpu_target"
            ),
        }

    if "disruption_budget" in spec:
        values["pdb"] = {
            "enabled": True,
            "minAvailable": _int(
                spec["disruption_budget"]["min_available"],
                "disruption_budget.min_available",
            ),
        }

    return values


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Translate a legacy env-spec into golden-service Helm values."
    )
    parser.add_argument("envspec", help="path to the env-spec YAML file")
    parser.add_argument(
        "-o", "--out", help="write values here instead of stdout", default=None
    )
    args = parser.parse_args(argv)

    try:
        values = translate(load(args.envspec))
    except BridgeError as err:
        print(f"env-spec-bridge: {err}", file=sys.stderr)
        return 1

    rendered = dump(values)
    if args.out:
        Path(args.out).write_text(rendered)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
