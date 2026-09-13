#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"
unset SSH_AUTH_SOCK

run_root=""
while (( $# )); do
  case "$1" in
    --run-root) run_root="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
validated_root="$(validate_run_root "$run_root")"
init_run_root "$validated_root"

test_acceptance() {
  require_eq "Shamu DeepSeek running" true \
    "${TEST_ACCEPTANCE_DEEPSEEK_SHAMU_RUNNING:-true}"
  require_eq "Tilikum DeepSeek running" true \
    "${TEST_ACCEPTANCE_DEEPSEEK_TILIKUM_RUNNING:-true}"
  require_eq "Shamu GLM stopped" false \
    "${TEST_ACCEPTANCE_GLM_SHAMU_RUNNING:-false}"
  require_eq "Tilikum GLM stopped" false \
    "${TEST_ACCEPTANCE_GLM_TILIKUM_RUNNING:-false}"
  require_eq "direct authenticated completion" 200 \
    "${TEST_ACCEPTANCE_DIRECT_STATUS:-200}"
  require_eq "missing direct key rejection" 401 \
    "${TEST_ACCEPTANCE_MISSING_KEY_STATUS:-401}"
  require_eq "wrong direct key rejection" 401 \
    "${TEST_ACCEPTANCE_WRONG_KEY_STATUS:-401}"
  require_eq "private model matrix" ok \
    "${TEST_ACCEPTANCE_PRIVATE_MODELS:-ok}"
  require_eq "public model matrix" ok \
    "${TEST_ACCEPTANCE_PUBLIC_MODELS:-ok}"
  require_eq "published metadata" ok \
    "${TEST_ACCEPTANCE_METADATA:-ok}"
  require_eq "Prometheus targets" ok \
    "${TEST_ACCEPTANCE_PROMETHEUS:-ok}"
  require_eq "Prometheus DeepSeek probe route" matched \
    "${TEST_ACCEPTANCE_PROMETHEUS_ROUTE:-matched}"
  require_eq "Langfuse trace" ok \
    "${TEST_ACCEPTANCE_LANGFUSE:-ok}"
  require_eq "Langfuse acceptance probe" matched \
    "${TEST_ACCEPTANCE_LANGFUSE_PROBE:-matched}"
  require_eq "Baker semantic snapshot" equal \
    "${TEST_ACCEPTANCE_BAKER_EQUAL:-equal}"
  require_eq "rollback path" ok \
    "${TEST_ACCEPTANCE_ROLLBACK:-ok}"
}

if [[ "${WEBSTER_ACCEPTANCE_TEST_MODE:-0}" == "1" ]]; then
  test_acceptance
  event publication-acceptance GO "test-mode publication matrix passed"
  printf 'publication acceptance validated in test mode\n'
  exit 0
fi

capture_baker_node() {
  local host="$1" role="$2" output="$3"
  shift 3
  ssh "$host" python3 - "$role" "$BAKER_CONTAINER" "$@" <<'PY' >"$output"
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

role, container_name, *docker = sys.argv[1:]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


result = subprocess.run(
    docker + ["inspect", container_name], capture_output=True, text=True
)
require(result.returncode == 0, f"Baker {role} container inspect failed")
records = json.loads(result.stdout)
require(isinstance(records, list) and len(records) == 1, "Baker inspect is malformed")
record = records[0]
config_root = Path.home() / "dspark-recipe"
require(config_root.is_dir() and not config_root.is_symlink(), "Baker config root is missing")
config_hashes = {}
config_links = {}
config_names = {
    ".env.dspark",
    "Dockerfile",
    "compose.yaml",
    "compose.yml",
    "docker-compose.yaml",
    "docker-compose.yml",
}
config_suffixes = {".conf", ".env", ".json", ".py", ".sh", ".toml", ".yaml", ".yml"}
for path in sorted(config_root.rglob("*")):
    relative = str(path.relative_to(config_root))
    if path.is_symlink():
        config_links[relative] = os.readlink(path)
    elif path.is_file() and (
        path.name in config_names or path.suffix.lower() in config_suffixes
    ):
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        config_hashes[relative] = digest.hexdigest()
require(".env.dspark" in config_hashes, "Baker .env.dspark identity is missing")
state = record.get("State") or {}
host_config = record.get("HostConfig") or {}
container_config = record.get("Config") or {}
mounts = [
    {
        "type": mount.get("Type"),
        "source": mount.get("Source"),
        "destination": mount.get("Destination"),
        "mode": mount.get("Mode"),
        "rw": mount.get("RW"),
        "propagation": mount.get("Propagation"),
    }
    for mount in record.get("Mounts") or []
]
mounts.sort(key=lambda item: (str(item["destination"]), str(item["source"])))
snapshot = {
    "role": role,
    "container": {
        "id": record.get("Id"),
        "image_id": record.get("Image"),
        "configured_image": container_config.get("Image"),
        "entrypoint": container_config.get("Entrypoint"),
        "cmd": container_config.get("Cmd"),
        "args": record.get("Args"),
        "state": {
            "status": state.get("Status"),
            "running": state.get("Running"),
            "paused": state.get("Paused"),
            "restarting": state.get("Restarting"),
            "oom_killed": state.get("OOMKilled"),
            "dead": state.get("Dead"),
        },
        "restart_count": record.get("RestartCount"),
        "network_mode": host_config.get("NetworkMode"),
        "ipc_mode": host_config.get("IpcMode"),
        "mounts": mounts,
    },
    "config_root": str(config_root),
    "config_sha256": config_hashes,
    "config_links": config_links,
}
require(snapshot["container"]["id"], "Baker container ID is missing")
require(snapshot["container"]["image_id"], "Baker image identity is missing")
require(snapshot["container"]["state"]["running"] is True, "Baker container is not running")
print(json.dumps(snapshot, sort_keys=True))
PY
  chmod 0600 "$output"
}

write_baker_snapshot() {
  local phase="$1" rank0 rank1 output
  rank0="$RUN_ROOT/logs/publication-baker-$phase-rank0.json"
  rank1="$RUN_ROOT/logs/publication-baker-$phase-rank1.json"
  output="$RUN_ROOT/logs/publication-baker-$phase.json"
  capture_baker_node "$BAKER_RANK0_HOST" rank0 "$rank0" docker
  capture_baker_node "$BAKER_RANK1_HOST" rank1 "$rank1" sudo -n docker
  python3 - "$rank0" "$rank1" "$BAKER_RANK0_NETBIRD" "$BAKER_API_PORT" <<'PY' >"$output"
import json
import re
import sys
import urllib.request
from pathlib import Path

rank0_path, rank1_path, host, port = sys.argv[1:]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


with urllib.request.urlopen(f"http://{host}:{port}/health", timeout=15) as response:
    health_status = response.status
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=15) as response:
    metrics_status = response.status
    metrics = response.read().decode("utf-8")
required = {
    "vllm:kv_cache_usage_perc",
    "vllm:num_requests_running",
    "vllm:num_requests_waiting",
    "vllm:request_success_total",
}
seen = set()
model_names = {name: set() for name in required}
for line in metrics.splitlines():
    if not line or line.startswith("#"):
        continue
    sample = line.split(None, 1)[0]
    name = sample.split("{", 1)[0]
    if name not in required:
        continue
    seen.add(name)
    labels = sample[len(name):]
    for match in re.finditer(r'(?:^|[,{}])model_name="((?:\\.|[^"])*)"', labels):
        model_names[name].add(match.group(1))
require(health_status == 200 and metrics_status == 200, "Baker health or metrics failed")
require(seen == required, "Baker required metrics are incomplete")
snapshot = {
    "rank0": json.loads(Path(rank0_path).read_text(encoding="utf-8")),
    "rank1": json.loads(Path(rank1_path).read_text(encoding="utf-8")),
    "metrics": {
        "health_status": health_status,
        "metrics_status": metrics_status,
        "required_families": sorted(required),
        "model_names": {name: sorted(model_names[name]) for name in sorted(required)},
    },
}
print(json.dumps(snapshot, sort_keys=True))
PY
  chmod 0600 "$output"
}

write_prometheus_snapshot() {
  local previous="${1:-}"
  python3 - "$PROMETHEUS_URL" "$SHAMU_NETBIRD:$CANARY_PORT" "$previous" <<'PY'
import json
import math
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

prometheus, instance, previous_path = sys.argv[1:]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fetch_json(path, parameters=None):
    suffix = ""
    if parameters:
        suffix = "?" + urllib.parse.urlencode(parameters)
    with urllib.request.urlopen(prometheus.rstrip("/") + path + suffix, timeout=15) as response:
        return json.load(response)


def inspect():
    targets_payload = fetch_json("/api/v1/targets")
    targets = targets_payload.get("data", {}).get("activeTargets", [])
    matched = [
        target
        for target in targets
        if target.get("labels", {}).get("instance") == instance
        and urllib.parse.urlparse(target.get("scrapeUrl", "")).netloc == instance
    ]
    require(matched, "Shamu :8000 is not an active Prometheus scrape target")
    require(
        all(target.get("health") == "up" for target in matched),
        "Shamu :8000 Prometheus scrape target is not up",
    )
    query = f'sum(vllm:request_success_total{{instance="{instance}"}})'
    counter_payload = fetch_json("/api/v1/query", {"query": query})
    require(counter_payload.get("status") == "success", "Prometheus counter query failed")
    rows = counter_payload.get("data", {}).get("result", [])
    require(len(rows) == 1, "Prometheus DeepSeek request counter is absent")
    try:
        counter = float(rows[0]["value"][1])
    except (KeyError, IndexError, TypeError, ValueError) as error:
        raise RuntimeError("Prometheus DeepSeek request counter is malformed") from error
    require(math.isfinite(counter) and counter >= 0, "Prometheus DeepSeek request counter is invalid")
    return matched, counter


baseline = None
if previous_path:
    previous = json.loads(Path(previous_path).read_text(encoding="utf-8"))
    baseline = previous.get("request_success_total")
    require(isinstance(baseline, (int, float)) and not isinstance(baseline, bool), "Prometheus baseline is malformed")
deadline = time.monotonic() + 90
while True:
    matched, counter = inspect()
    if baseline is None or counter > baseline:
        break
    if time.monotonic() >= deadline:
        raise RuntimeError("Prometheus DeepSeek counter did not increase after the acceptance probe")
    time.sleep(5)
print(json.dumps({
    "instance": instance,
    "request_success_total": counter,
    "active_up_targets": [
        {"health": target.get("health"), "scrape_url": target.get("scrapeUrl")}
        for target in matched
    ],
}, sort_keys=True))
PY
}

"$script_dir/preflight.sh" --phase publish --run-root "$RUN_ROOT"

[[ -f "$RUN_ROOT/rollback.env" && ! -L "$RUN_ROOT/rollback.env" ]] ||
  die "rollback.env is missing"
require_eq "rollback.env mode" 600 "$(stat -c %a "$RUN_ROOT/rollback.env")"
declare -A rollback
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  case "$key" in
    ALIAS_CONFIG_BACKUP|ALIAS_CONFIG_SHA256|PUBLISH_CONFIG_BACKUP|PUBLISH_CONFIG_SHA256)
      rollback["$key"]="$value"
      ;;
    *) die "unknown rollback.env field: $key" ;;
  esac
done <"$RUN_ROOT/rollback.env"
publish_backup="${rollback[PUBLISH_CONFIG_BACKUP]:-}"
publish_hash="${rollback[PUBLISH_CONFIG_SHA256]:-}"
[[ "$publish_backup" == /home/nvidia/litellm/* && "$publish_backup" != *'/../'* ]] ||
  die "PUBLISH_CONFIG_BACKUP escaped the LiteLLM directory"
[[ "$publish_hash" =~ ^[0-9a-f]{64}$ ]] || die "PUBLISH_CONFIG_SHA256 is invalid"
require_eq "publication rollback mode" 600 \
  "$(ssh spark-1 "stat -c %a -- '$publish_backup'")"
require_eq "publication rollback hash" "$publish_hash" \
  "$(ssh spark-1 "sha256sum -- '$publish_backup' | awk '{print \$1}'")"
[[ -x "$script_dir/restore-litellm-config.sh" ]] || die "rollback entry point is missing"

source "$RUN_ROOT/manifest.env"
[[ "$VLLM_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || die "VLLM_IMAGE_ID is invalid"
rank_summary() {
  local host="$1" role="$2"
  shift 2
  ssh "$host" python3 - "$role" "$VLLM_IMAGE_ID" "$@" <<'PY'
import json
import subprocess
import sys

role, expected_image, *docker = sys.argv[1:]


def inspect(name):
    result = subprocess.run(docker + ["inspect", name], capture_output=True, text=True)
    if result.returncode:
        return None
    return json.loads(result.stdout)[0]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


deepseek = inspect("deepseek-v41-flash-tp2")
glm = inspect("glm52-full-mtp")
require(deepseek is not None and glm is not None, "serving containers are missing")
args = deepseek["Args"]
environment = deepseek["Config"].get("Env") or []
key_present = any(
    item.startswith(("VLLM_API_KEY=", "DSPARK_API_KEYS="))
    and item.split("=", 1)[1]
    for item in environment
)
require(deepseek["Image"] == expected_image, "DeepSeek image is wrong")
require(deepseek["State"]["Running"] is True, "DeepSeek is not running")
require(deepseek["RestartCount"] == 0, "DeepSeek restart count is nonzero")
require(glm["State"]["Running"] is False, "station GLM is still running")
require(("--headless" in args) is (role == "worker"), "rank role is wrong")
require(key_present is (role == "head"), "rank credential isolation is wrong")
require("--tensor-parallel-size" in args and args[args.index("--tensor-parallel-size") + 1] == "2", "TP size is wrong")
require("--pipeline-parallel-size" in args and args[args.index("--pipeline-parallel-size") + 1] == "1", "PP size is wrong")
require("--max-model-len" in args and args[args.index("--max-model-len") + 1] == "1048576", "context is wrong")
require("--max-num-seqs" in args and args[args.index("--max-num-seqs") + 1] == "4", "max sequences is wrong")
print(json.dumps({
    "role": role,
    "id": deepseek["Id"],
    "image": deepseek["Image"],
    "running": True,
    "restarts": 0,
    "headless": "--headless" in args,
    "key_present": bool(key_present),
}, sort_keys=True))
PY
}
rank_summary shamu head docker >"$RUN_ROOT/logs/publication-rank-shamu.json"
rank_summary tilikum worker sudo -n docker >"$RUN_ROOT/logs/publication-rank-tilikum.json"
chmod 0600 "$RUN_ROOT/logs/publication-rank-"*.json
require_eq "Shamu listener" "$SHAMU_NETBIRD:$CANARY_PORT" \
  "$(ssh shamu "ss -lntH '( sport = :$CANARY_PORT )' | awk '{print \$4}'")"
if ssh tilikum "ss -lntH '( sport = :$CANARY_PORT )' | grep -q ."; then
  die "Tilikum exposes an HTTP listener"
fi
require_eq "watchdog enabled" enabled "$(systemctl is-enabled deepseek-v41-watchdog.timer)"
require_eq "watchdog active" active "$(systemctl is-active deepseek-v41-watchdog.timer)"

python3 - "$RUN_ROOT" "$SHAMU_NETBIRD" "$CANARY_PORT" <<'PY'
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

run_root, host, port = sys.argv[1:]
key_path = Path(run_root) / "credentials/deepseek-v41.key"
def require(condition, message):
    if not condition:
        raise RuntimeError(message)


require(key_path.is_file() and not key_path.is_symlink(), "credential is missing or unsafe")
require(stat.S_IMODE(key_path.stat().st_mode) == 0o600, "credential mode is not 0600")
key = key_path.read_text(encoding="utf-8").strip()
base = f"http://{host}:{port}"


def request(path, body=None, token=None):
    headers = {}
    data = None
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body, separators=(",", ":")).encode()
    value = urllib.request.Request(
        base + path,
        data=data,
        headers=headers,
        method="POST" if body is not None else "GET",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(value, timeout=180) as response:
            return response.status, json.load(response), time.monotonic() - started
    except urllib.error.HTTPError as error:
        return error.code, None, time.monotonic() - started


missing, _, _ = request("/v1/models")
wrong, _, _ = request("/v1/models", token="intentionally-wrong")
models_status, models, _ = request("/v1/models", token=key)
status, payload, latency = request(
    "/v1/chat/completions",
    {
        "model": "deepseek-ai/DeepSeek-V4.1-Flash",
        "messages": [{"role": "user", "content": "Reply with exactly OK."}],
        "max_tokens": 16,
        "temperature": 0,
        "reasoning_effort": "none",
    },
    key,
)
require((missing, wrong, models_status, status) == (401, 401, 200, 200), "station authentication responses are wrong")
require(any(item.get("id") == "deepseek-ai/DeepSeek-V4.1-Flash" for item in models["data"]), "served model is absent")
require(payload.get("choices"), "station completion has no choices")
result = {
    "missing_key_status": missing,
    "wrong_key_status": wrong,
    "models_status": models_status,
    "completion_status": status,
    "response_model": payload.get("model"),
    "latency_seconds": round(latency, 6),
}
output = Path(run_root) / "logs/publication-direct.json"
temporary = output.with_name(output.name + f".tmp.{os.getpid()}")
temporary.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, output)
PY

ssh spark-1 python3 - "$(basename "$RUN_ROOT")" \
  <"$script_dir/current-model-probes.py" \
  >"$RUN_ROOT/logs/publication-private-models.json"
chmod 0600 "$RUN_ROOT/logs/publication-private-models.json"

probe_id="deepseek-v41-acceptance-$(basename "$RUN_ROOT")-$(date -u +%s)-$$"
probe_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_baker_snapshot before
write_prometheus_snapshot >"$RUN_ROOT/logs/publication-prometheus-before.json"
chmod 0600 "$RUN_ROOT/logs/publication-prometheus-before.json"

ssh spark-1 python3 - "$probe_id" \
  <"$script_dir/publication-model-probes.py" \
  >"$RUN_ROOT/logs/publication-public-models.json"
chmod 0600 "$RUN_ROOT/logs/publication-public-models.json"

write_prometheus_snapshot \
  "$RUN_ROOT/logs/publication-prometheus-before.json" \
  >"$RUN_ROOT/logs/publication-prometheus.json"
chmod 0600 "$RUN_ROOT/logs/publication-prometheus.json"

ssh spark-1 python3 - "$probe_id" "$probe_started_at" <<'PY' >"$RUN_ROOT/logs/publication-langfuse.json"
import base64
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request

probe_id, started_at = sys.argv[1:]
environment = subprocess.check_output(
    ["docker", "inspect", "litellm", "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
    text=True,
).splitlines()
values = {item.split("=", 1)[0]: item.split("=", 1)[1] for item in environment if "=" in item}
host = values["LANGFUSE_HOST"].rstrip("/")
credentials = base64.b64encode(
    (values["LANGFUSE_PUBLIC_KEY"] + ":" + values["LANGFUSE_SECRET_KEY"]).encode()
).decode()


def contains_exact(value, expected):
    if isinstance(value, str):
        return value == expected
    if isinstance(value, list):
        return any(contains_exact(item, expected) for item in value)
    if isinstance(value, dict):
        return any(contains_exact(item, expected) for item in value.values())
    return False


parameters = urllib.parse.urlencode({
    "limit": 100,
    "orderBy": "timestamp.desc",
    "fromTimestamp": started_at,
    "userId": probe_id,
})
deadline = time.monotonic() + 120
matched = None
while time.monotonic() < deadline:
    request = urllib.request.Request(
        host + "/api/public/traces?" + parameters,
        headers={"Authorization": "Basic " + credentials},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = json.load(response)
    for row in payload.get("data", []):
        if contains_exact(row, probe_id) and contains_exact(row, "deepseek-v4.1-flash"):
            matched = row
            break
    if matched is not None:
        break
    time.sleep(5)
if matched is None:
    raise RuntimeError("no Langfuse trace matched the exact acceptance probe and DeepSeek route")
print(json.dumps({
    "host": host,
    "probe_id": probe_id,
    "trace": {
        "id": matched.get("id"),
        "timestamp": matched.get("timestamp") or matched.get("createdAt"),
        "name": matched.get("name"),
        "deepseek_route": "deepseek-v4.1-flash",
    },
}, sort_keys=True))
PY
chmod 0600 "$RUN_ROOT/logs/publication-langfuse.json"

write_baker_snapshot after
python3 - \
  "$RUN_ROOT/logs/publication-baker-before.json" \
  "$RUN_ROOT/logs/publication-baker-after.json" <<'PY'
import json
import sys
from pathlib import Path

before_path, after_path = map(Path, sys.argv[1:])
before = json.loads(before_path.read_text(encoding="utf-8"))
after = json.loads(after_path.read_text(encoding="utf-8"))
if before != after:
    raise RuntimeError("Baker container, config, identity, or metric semantics drifted")
PY

event publication-acceptance GO \
  "direct/private/public models, metadata, ingress, observability, watchdog, and rollback passed"
printf 'GO publication acceptance run_root=%s\n' "$RUN_ROOT"
