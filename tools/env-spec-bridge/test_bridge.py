"""Tests for the env-spec -> golden-service values bridge (U13, R4).

Two kinds of assertion:
  1. Golden-file: each env-spec fixture translates byte-for-byte to a checked-in
     expected values file (determinism, Success Criterion 5).
  2. Schema: every generated values file renders under `helm template`, which
     validates it against charts/golden-service/values.schema.json. Helm is the
     validator (jsonschema is not stdlib); an exit 0 means schema-valid.

Error fixtures assert the bridge hard-errors and names the offending key
(no silent drops, R10).
"""

import shutil
import subprocess
from pathlib import Path

import pytest

import bridge

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CHART = REPO / "charts" / "golden-service"
FIX = HERE / "fixtures"
EXPECTED = FIX / "expected"

# Fixtures that translate cleanly to a golden values file.
TRANSLATE_CASES = ["web-payments", "inference-vision", "web-checkout"]

helm_required = pytest.mark.skipif(
    shutil.which("helm") is None, reason="helm not installed"
)


@pytest.mark.parametrize("name", TRANSLATE_CASES)
def test_translation_matches_golden(name):
    spec = bridge.load(FIX / f"{name}.envspec.yaml")
    got = bridge.dump(bridge.translate(spec))
    want = (EXPECTED / f"{name}.values.yaml").read_text()
    assert got == want


@helm_required
@pytest.mark.parametrize("name", TRANSLATE_CASES)
def test_generated_values_pass_helm_schema(name, tmp_path):
    spec = bridge.load(FIX / f"{name}.envspec.yaml")
    values = tmp_path / "values.yaml"
    values.write_text(bridge.dump(bridge.translate(spec)))
    result = subprocess.run(
        ["helm", "template", "t", str(CHART), "-f", str(values)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


@helm_required
def test_committed_expected_files_are_schema_valid(tmp_path):
    # The golden files themselves must stay schema-valid, independent of the
    # translator, so a stale expected file can never mask a schema break.
    for name in TRANSLATE_CASES:
        values = EXPECTED / f"{name}.values.yaml"
        result = subprocess.run(
            ["helm", "template", "t", str(CHART), "-f", str(values)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"{name}: {result.stderr}"


def test_determinism_repeated_translation():
    a = bridge.dump(bridge.translate(bridge.load(FIX / "inference-vision.envspec.yaml")))
    b = bridge.dump(bridge.translate(bridge.load(FIX / "inference-vision.envspec.yaml")))
    assert a == b


def test_unknown_key_errors_with_name():
    spec = bridge.load(FIX / "errors" / "unknown-key.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    assert "network_mode" in str(exc.value)


def test_env_vars_error_redirects_to_eso():
    spec = bridge.load(FIX / "errors" / "env-vars.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    msg = str(exc.value)
    assert "env" in msg and "ESO" in msg


def test_missing_required_key_errors_by_name():
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(
            {"service": "x", "class": "web", "image": "r:1", "cpu": "1", "memory": "1Gi"}
        )
    assert "team" in str(exc.value)


def test_bad_image_errors():
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(
            {
                "service": "x",
                "team": "t",
                "class": "web",
                "image": "noimagetag",
                "cpu": "1",
                "memory": "1Gi",
            }
        )
    assert "image" in str(exc.value)


def test_bad_class_errors():
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(
            {
                "service": "x",
                "team": "t",
                "class": "batch",
                "image": "r:1",
                "cpu": "1",
                "memory": "1Gi",
            }
        )
    assert "batch" in str(exc.value) or "class" in str(exc.value)


def test_unknown_subkey_errors_with_dotted_name():
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(
            {
                "service": "x",
                "team": "t",
                "class": "web",
                "image": "r:1",
                "cpu": "1",
                "memory": "1Gi",
                "healthcheck": {"path": "/h", "grace_period": 30},
            }
        )
    assert "healthcheck.grace_period" in str(exc.value)


def test_generic_unknown_key_errors_by_name():
    # A key that is neither known nor a tailored ECS-ism falls to the generic
    # "not part of the env-spec contract" branch and must name the key (R10).
    spec = bridge.load(FIX / "errors" / "generic-unknown-key.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    msg = str(exc.value)
    assert "frobnicate" in msg and "contract" in msg


def test_partial_autoscale_errors_naming_missing_subkey():
    spec = bridge.load(FIX / "errors" / "partial-autoscale.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    msg = str(exc.value)
    assert "autoscale" in msg and ("min" in msg or "max" in msg)


def test_scalar_healthcheck_errors_as_not_a_mapping():
    spec = bridge.load(FIX / "errors" / "scalar-healthcheck.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    msg = str(exc.value)
    assert "healthcheck" in msg and "mapping" in msg


def test_non_int_port_errors_by_name():
    spec = bridge.load(FIX / "errors" / "non-int-port.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    assert "port" in str(exc.value)


def test_non_int_replicas_rejected_not_truncated():
    spec = bridge.load(FIX / "errors" / "non-int-replicas.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    assert "replicas" in str(exc.value)


def test_bare_numeric_cpu_errors_naming_key():
    spec = bridge.load(FIX / "errors" / "bare-numeric-cpu.envspec.yaml")
    with pytest.raises(bridge.BridgeError) as exc:
        bridge.translate(spec)
    assert "cpu" in str(exc.value)


def test_malformed_yaml_errors_as_bridge_error(tmp_path):
    bad = tmp_path / "bad.envspec.yaml"
    bad.write_text("service: x\n  bad: : indentation\n:::\n")
    with pytest.raises(bridge.BridgeError):
        bridge.load(bad)


def test_missing_file_errors_as_bridge_error(tmp_path):
    with pytest.raises(bridge.BridgeError):
        bridge.load(tmp_path / "does-not-exist.yaml")
