#!/usr/bin/env python3
"""Select an immutable vLLM source pin from fail-closed GitHub evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


REPOSITORY = "vllm-project/vllm"
RUNS_ROOT = Path("/home/ubuntu/deepseek-v41-runs")
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
PASSING_CHECK_CONCLUSIONS = {"success", "neutral", "skipped"}


class PinRejected(RuntimeError):
    """The available evidence does not authorize an immutable runtime pin."""


def require_sha(value: object, label: str) -> str:
    if not isinstance(value, str) or not FULL_SHA.fullmatch(value):
        raise PinRejected(f"{label} is not a full commit SHA")
    return value


def checks_pass(commit_status: dict, check_runs: dict) -> None:
    status_state = commit_status.get("state")
    if status_state != "success":
        raise PinRejected(f"commit status is {status_state or 'missing'}")
    statuses = commit_status.get("statuses")
    total_statuses = commit_status.get("total_count")
    if not isinstance(statuses, list) or not isinstance(total_statuses, int):
        raise PinRejected("commit status evidence is malformed")
    if total_statuses < 1 or len(statuses) != total_statuses:
        raise PinRejected("commit status evidence is incomplete")
    for item in statuses:
        if item.get("state") != "success":
            raise PinRejected(
                "commit status did not pass: "
                f"{item.get('context', '<unnamed>')}={item.get('state', 'missing')}"
            )

    runs = check_runs.get("check_runs")
    total_runs = check_runs.get("total_count")
    if not isinstance(runs, list) or not isinstance(total_runs, int):
        raise PinRejected("check-run evidence is malformed")
    if total_runs < 1 or len(runs) != total_runs:
        raise PinRejected("check-run evidence is incomplete")
    for item in runs:
        status = item.get("status")
        conclusion = item.get("conclusion")
        if status != "completed" or conclusion not in PASSING_CHECK_CONCLUSIONS:
            raise PinRejected(
                "check run did not pass: "
                f"{item.get('name', '<unnamed>')}={status}/{conclusion}"
            )


def latest_statuses_by_context(history: list[dict]) -> list[dict]:
    latest = {}
    for item in history:
        context = item.get("context")
        if not isinstance(context, str) or not context:
            raise PinRejected("commit status history contains an unnamed context")
        previous = latest.get(context)
        if previous is None or (item.get("created_at") or "") > (
            previous.get("created_at") or ""
        ):
            latest[context] = item
    return [latest[context] for context in sorted(latest)]


def require_stable_pr(before: dict, after: dict) -> None:
    before_state = {
        "state": before.get("state"),
        "draft": before.get("draft"),
        "merged": before.get("merged"),
        "mergeable_state": before.get("mergeable_state"),
        "updated_at": before.get("updated_at"),
        "head_sha": (before.get("head") or {}).get("sha"),
    }
    after_state = {
        "state": after.get("state"),
        "draft": after.get("draft"),
        "merged": after.get("merged"),
        "mergeable_state": after.get("mergeable_state"),
        "updated_at": after.get("updated_at"),
        "head_sha": (after.get("head") or {}).get("sha"),
    }
    if before_state != after_state:
        raise PinRejected("PR changed during evidence collection")


def reviews_pass(reviews: list[dict], head_sha: str) -> None:
    latest_by_reviewer = {}
    for review in reviews:
        user = review.get("user") or {}
        login = user.get("login")
        if login:
            latest_by_reviewer[login] = review
    current = [
        review
        for review in latest_by_reviewer.values()
        if review.get("commit_id") == head_sha
    ]
    if any(review.get("state") == "CHANGES_REQUESTED" for review in current):
        raise PinRejected("current head has a changes-requested review")
    if not any(review.get("state") == "APPROVED" for review in current):
        raise PinRejected("current head has no approving review")


def select_runtime_pin(
    pr: dict,
    reviews: list[dict],
    commit_status: dict,
    check_runs: dict,
    releases: list[dict],
) -> dict[str, str]:
    head_sha = require_sha((pr.get("head") or {}).get("sha"), "PR head")
    if pr.get("merged") is True:
        for release in releases:
            if release.get("draft") or release.get("prerelease"):
                continue
            if release.get("contains_merge_commit") is True:
                tag = release.get("tag_name")
                commit = require_sha(release.get("target_commit"), "release commit")
                if not isinstance(tag, str) or not tag:
                    raise PinRejected("containing release has no tag")
                return {"commit": commit, "source": f"release:{tag}"}
        checks_pass(commit_status, check_runs)
        reviews_pass(reviews, head_sha)
        return {
            "commit": require_sha(pr.get("merge_commit_sha"), "PR merge commit"),
            "source": "pr-merge",
        }

    if pr.get("state") != "open":
        raise PinRejected(f"PR state is {pr.get('state') or 'missing'}")
    if pr.get("draft") is not False:
        raise PinRejected("PR is draft or draft state is missing")
    mergeable_state = pr.get("mergeable_state")
    if mergeable_state != "clean":
        raise PinRejected(f"PR mergeable_state={mergeable_state or 'missing'}")
    checks_pass(commit_status, check_runs)
    reviews_pass(reviews, head_sha)
    return {"commit": head_sha, "source": "pr-head"}


def update_manifest(path: Path, commit: str) -> None:
    require_sha(commit, "selected runtime commit")
    if path.stat().st_mode & 0o777 != 0o600:
        raise PinRejected("manifest mode must be 0600")
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    indexes = [index for index, line in enumerate(lines) if line.startswith("VLLM_COMMIT=")]
    if len(indexes) != 1:
        raise PinRejected("manifest must contain exactly one VLLM_COMMIT field")
    index = indexes[0]
    existing = lines[index].rstrip("\r\n").split("=", 1)[1]
    if existing and existing != commit:
        raise PinRejected("manifest already pins a different VLLM_COMMIT")
    lines[index] = f"VLLM_COMMIT={commit}\n"
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.writelines(lines)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def write_json(path: Path, payload: object) -> None:
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def append_event(run_root: Path, decision: str, reason: str) -> None:
    clean_reason = reason.replace("\t", " ").replace("\n", " ")
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with (run_root / "events.tsv").open("a", encoding="utf-8") as stream:
        stream.write(f"{timestamp}\truntime-pin\t{decision}\t{clean_reason}\n")


def resolve_run_root(manifest: Path) -> Path:
    manifest = manifest.resolve()
    run_root = manifest.parent
    try:
        relative = run_root.relative_to(RUNS_ROOT)
    except ValueError as error:
        raise PinRejected("manifest must be beneath the approved run root") from error
    if len(relative.parts) != 1 or not re.fullmatch(
        r"[0-9]{8}T[0-9]{6}Z", relative.parts[0]
    ):
        raise PinRejected("manifest run root must end in one UTC change id")
    if manifest.name != "manifest.env" or not manifest.is_file():
        raise PinRejected("manifest.env does not exist")
    if manifest.stat().st_mode & 0o777 != 0o600:
        raise PinRejected("manifest mode must be 0600")
    return run_root


class GitHubClient:
    def __init__(self, token: str | None):
        self.token = token

    def get(self, path: str) -> object:
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "webster-deepseek-v41-runtime-pin",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(
            "https://api.github.com" + path,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise PinRejected(
                f"GitHub API request failed path={path} status={error.code}"
            ) from None

    def paginated_list(self, path: str) -> list[dict]:
        separator = "&" if "?" in path else "?"
        rows = []
        page = 1
        while True:
            payload = self.get(f"{path}{separator}per_page=100&page={page}")
            if not isinstance(payload, list):
                raise PinRejected(f"GitHub API list is malformed path={path}")
            rows.extend(payload)
            if len(payload) < 100:
                return rows
            page += 1

    def all_check_runs(self, commit: str) -> dict:
        runs = []
        total = None
        page = 1
        while True:
            payload = self.get(
                f"/repos/{REPOSITORY}/commits/{commit}/check-runs?per_page=100&page={page}"
            )
            if not isinstance(payload, dict) or not isinstance(payload.get("check_runs"), list):
                raise PinRejected("GitHub check-run evidence is malformed")
            if total is None:
                total = payload.get("total_count")
            page_runs = payload["check_runs"]
            runs.extend(page_runs)
            if len(page_runs) < 100:
                break
            page += 1
        return {"total_count": total, "check_runs": runs}


def github_token() -> str | None:
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        if os.environ.get(name):
            return os.environ[name]
    try:
        result = subprocess.run(
            ["gh", "auth", "token"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip() or None


def release_containment(client: GitHubClient, pr: dict, releases: list[dict]) -> list[dict]:
    if pr.get("merged") is not True:
        return []
    merge_commit = require_sha(pr.get("merge_commit_sha"), "PR merge commit")
    merged_at = pr.get("merged_at") or ""
    evidence = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        if merged_at and (release.get("published_at") or "") < merged_at:
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or not tag:
            continue
        encoded_tag = urllib.parse.quote(tag, safe="")
        target = client.get(f"/repos/{REPOSITORY}/commits/{encoded_tag}")
        if not isinstance(target, dict):
            raise PinRejected(f"release target evidence is malformed tag={tag}")
        target_commit = require_sha(target.get("sha"), f"release {tag} commit")
        comparison = client.get(
            f"/repos/{REPOSITORY}/compare/{merge_commit}...{target_commit}"
        )
        if not isinstance(comparison, dict):
            raise PinRejected(f"release containment evidence is malformed tag={tag}")
        evidence.append(
            {
                "tag_name": tag,
                "target_commit": target_commit,
                "contains_merge_commit": comparison.get("status") in {"ahead", "identical"},
                "compare_status": comparison.get("status"),
                "draft": False,
                "prerelease": False,
            }
        )
    return evidence


def collect_evidence(client: GitHubClient, pr_number: int) -> dict[str, object]:
    pr_path = f"/repos/{REPOSITORY}/pulls/{pr_number}"
    pr = client.get(pr_path)
    if not isinstance(pr, dict):
        raise PinRejected("GitHub PR evidence is malformed")
    head_sha = require_sha((pr.get("head") or {}).get("sha"), "PR head")
    reviews = client.paginated_list(pr_path + "/reviews")
    combined_status = client.get(f"/repos/{REPOSITORY}/commits/{head_sha}/status")
    if not isinstance(combined_status, dict):
        raise PinRejected("GitHub commit-status evidence is malformed")
    status_history = client.paginated_list(
        f"/repos/{REPOSITORY}/commits/{head_sha}/statuses"
    )
    combined_status["statuses"] = latest_statuses_by_context(status_history)
    check_runs = client.all_check_runs(head_sha)
    releases = client.paginated_list(f"/repos/{REPOSITORY}/releases")
    containment = release_containment(client, pr, releases)
    pr_recheck = client.get(pr_path)
    if not isinstance(pr_recheck, dict):
        raise PinRejected("GitHub PR recheck evidence is malformed")
    require_stable_pr(pr, pr_recheck)
    return {
        "pr": pr,
        "pr-recheck": pr_recheck,
        "reviews": reviews,
        "commit-status": combined_status,
        "check-runs": check_runs,
        "releases": releases,
        "release-containment": containment,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    run_root = resolve_run_root(args.manifest)
    evidence_dir = run_root / "runtime-pin"
    evidence_dir.mkdir(mode=0o700, exist_ok=True)
    os.chmod(evidence_dir, 0o700)
    try:
        evidence = collect_evidence(GitHubClient(github_token()), args.pr)
        for name, payload in evidence.items():
            write_json(evidence_dir / f"{name}.json", payload)
        selected = select_runtime_pin(
            evidence["pr"],
            evidence["reviews"],
            evidence["commit-status"],
            evidence["check-runs"],
            evidence["release-containment"],
        )
        update_manifest(args.manifest, selected["commit"])
    except PinRejected as error:
        reason = str(error)
        write_json(evidence_dir / "decision.json", {"decision": "NO-GO", "reason": reason})
        append_event(run_root, "NO-GO", reason)
        print(f"NO-GO runtime-pin: {reason}", file=sys.stderr)
        return 1
    write_json(evidence_dir / "decision.json", {"decision": "GO", **selected})
    append_event(run_root, "GO", f"source={selected['source']} commit={selected['commit']}")
    print(f"GO runtime-pin source={selected['source']} commit={selected['commit']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
