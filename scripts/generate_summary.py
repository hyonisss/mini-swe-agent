#!/usr/bin/env python3
"""Generate summary.json from mini-swe-agent results and swebench evaluation.

Usage (must run AFTER swebench.harness.run_evaluation):

  python scripts/generate_summary.py results/my-model \\
    --eval-results logs/run_evaluation \\
    --run-id my-model-eval \\
    --dataset data/swebench_lite_test2.jsonl

Output: results/my-model/summary.json
"""

import argparse
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Grade thresholds (validated against reference summary.json)
# ---------------------------------------------------------------------------

def _grade(metric: str, value: float) -> str:
    """Return A/B/C/D grade for a metric value."""
    # (threshold, grade) ordered from best to worst
    thresholds: dict[str, list[tuple[float, str]]] = {
        # higher is better
        "task_resolution_rate": [(0.5, "A"), (0.3, "B"), (0.15, "C"), (0.0, "D")],
        # lower is better
        "token_efficiency":         [(200_000, "A"), (350_000, "B"), (500_000, "C")],
        "cost_per_resolved_task":   [(1.0, "A"), (2.0, "B"), (3.0, "C")],
        "e2e_time":                 [(120, "A"), (300, "B"), (600, "C")],
        "time_to_first_action":     [(5, "A"), (10, "B"), (20, "C")],
        "convergence_steps":        [(15, "A"), (25, "B"), (40, "C")],
    }
    if metric == "task_resolution_rate":
        for threshold, grade in thresholds[metric]:
            if value >= threshold:
                return grade
        return "D"
    else:
        for threshold, grade in thresholds[metric]:
            if value < threshold:
                return grade
        return "D"


# ---------------------------------------------------------------------------
# traj.json helpers
# ---------------------------------------------------------------------------

def _load_traj(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text())
    return {}


def _get_tokens(traj: dict) -> int:
    total = 0
    for msg in traj.get("messages", []):
        usage = (msg.get("extra") or {}).get("response", {})
        if isinstance(usage, dict):
            usage = usage.get("usage", {}) or {}
            total += usage.get("total_tokens", 0)
    return total


def _get_timing(traj: dict) -> tuple[float, float]:
    """Return (e2e_time_sec, time_to_first_action_sec)."""
    info = traj.get("info", {})
    started_at = info.get("started_at")
    completed_at = info.get("completed_at")

    # e2e_time
    if started_at and completed_at:
        e2e_time = completed_at - started_at
    else:
        # fallback: span of message timestamps
        timestamps = [
            msg["extra"]["timestamp"]
            for msg in traj.get("messages", [])
            if msg.get("extra", {}).get("timestamp")
        ]
        e2e_time = (max(timestamps) - min(timestamps)) if len(timestamps) >= 2 else 0.0

    # time_to_first_action: start → first LLM response timestamp
    first_ts = next(
        (msg["extra"]["timestamp"] for msg in traj.get("messages", [])
         if msg.get("extra", {}).get("timestamp")),
        None,
    )
    if started_at and first_ts:
        time_to_first_action = first_ts - started_at
    else:
        time_to_first_action = 0.0

    return e2e_time, time_to_first_action


# ---------------------------------------------------------------------------
# swebench harness results helpers
# ---------------------------------------------------------------------------

def _load_harness_results(eval_dir: Path, run_id: str) -> dict:
    """Find and return the harness results.json for this run_id."""
    # harness saves as <model_name>.<run_id>.json
    for f in eval_dir.glob(f"*.{run_id}.json"):
        return json.loads(f.read_text())
    # fallback: any json containing resolved_ids
    for f in eval_dir.glob("*.json"):
        data = json.loads(f.read_text())
        if "resolved_ids" in data:
            return data
    return {}


def _load_instance_report(eval_dir: Path, run_id: str, instance_id: str) -> dict:
    """Return the per-instance report dict (keyed by instance_id) from report.json."""
    # harness path: <eval_dir>/<run_id>/<model_name>/<instance_id>/report.json
    for report_file in eval_dir.rglob(f"{instance_id}/report.json"):
        data = json.loads(report_file.read_text())
        return data.get(instance_id, {})
    return {}


def _eval_counts(report: dict) -> tuple[int, int, int, int]:
    """Return (ftp_total, ftp_passed, ptp_total, ptp_passed) from report dict."""
    ts = report.get("tests_status", {})
    ftp = ts.get("FAIL_TO_PASS", {})
    ptp = ts.get("PASS_TO_PASS", {})
    ftp_passed = len(ftp.get("success", []))
    ftp_total = ftp_passed + len(ftp.get("failure", []))
    ptp_passed = len(ptp.get("success", []))
    ptp_total = ptp_passed + len(ptp.get("failure", []))
    return ftp_total, ftp_passed, ptp_total, ptp_passed


# ---------------------------------------------------------------------------
# Environment info
# ---------------------------------------------------------------------------

def _env_info() -> str:
    import platform
    os_name = platform.system().lower()
    if os_name == "linux":
        try:
            if "microsoft" in Path("/proc/version").read_text().lower():
                os_name = "wsl"
        except OSError:
            pass
    disk_gb = "unknown"
    try:
        total = shutil.disk_usage("/").total
        disk_gb = f"{total / 1e9:.1f}GB"
    except OSError:
        pass
    ram_gb = "unknown"
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal"):
                ram_gb = f"{int(line.split()[1]) / 1e6:.1f}GB"
                break
    except OSError:
        pass
    docker = "Yes" if shutil.which("docker") else "No"
    return f"OS: {os_name} | Disk: {disk_gb} | RAM: {ram_gb} | Docker: {docker}"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate summary.json from mini-swe-agent + swebench harness results."
    )
    parser.add_argument("agent_results_dir", help="Directory containing preds.json and per-instance traj.json files")
    parser.add_argument("--eval-results", required=True, metavar="DIR",
                        help="Directory produced by swebench.harness.run_evaluation (contains *.json and <run_id>/ subdirectory)")
    parser.add_argument("--run-id", required=True, metavar="RUN_ID",
                        help="--run_id value used when calling swebench.harness.run_evaluation")
    parser.add_argument("--dataset", default="data/swebench_lite_test2.jsonl", metavar="JSONL",
                        help="Dataset JSONL file (used as fallback for FAIL_TO_PASS/PASS_TO_PASS totals)")
    parser.add_argument("--agent-name", default="mini-swe-agent")
    parser.add_argument("--model-name", default="", metavar="MODEL")
    parser.add_argument("-o", "--output", metavar="PATH",
                        help="Output path (default: <agent_results_dir>/summary.json)")
    args = parser.parse_args()

    agent_dir = Path(args.agent_results_dir)
    eval_dir = Path(args.eval_results)

    # --- validate inputs ---
    if not agent_dir.is_dir():
        sys.exit(f"ERROR: agent_results_dir not found: {agent_dir}")
    if not eval_dir.is_dir():
        sys.exit(f"ERROR: --eval-results directory not found: {eval_dir}")

    harness_results = _load_harness_results(eval_dir, args.run_id)
    if not harness_results:
        sys.exit(
            f"ERROR: could not find harness results for run_id='{args.run_id}' in {eval_dir}.\n"
            "Make sure you ran: python -m swebench.harness.run_evaluation --run_id " + args.run_id
        )

    resolved_ids: set[str] = set(harness_results.get("resolved_ids", []))

    # --- load dataset for fallback totals ---
    dataset_instances: dict[str, dict] = {}
    dataset_path = Path(args.dataset)
    if dataset_path.exists():
        for line in dataset_path.read_text().splitlines():
            if line.strip():
                inst = json.loads(line)
                dataset_instances[inst["instance_id"]] = inst

    # --- load preds.json ---
    preds_file = agent_dir / "preds.json"
    if not preds_file.exists():
        sys.exit(f"ERROR: preds.json not found in {agent_dir}")
    preds: dict[str, dict] = json.loads(preds_file.read_text())

    # collect all instance_ids (from preds + traj files)
    instance_ids: list[str] = list(preds.keys())
    for traj_file in agent_dir.rglob("*.traj.json"):
        iid = traj_file.stem.replace(".traj", "")
        if iid not in instance_ids:
            instance_ids.append(iid)
    instance_ids = sorted(instance_ids)

    # --- per-task processing ---
    per_task: list[dict] = []
    success_count = fail_count = resolved_count = 0
    all_costs: list[float] = []
    all_tokens: list[int] = []
    all_steps: list[int] = []
    all_e2e: list[float] = []
    all_first_action: list[float] = []
    wall_start: float | None = None
    wall_end: float | None = None

    for instance_id in instance_ids:
        traj_path = agent_dir / instance_id / f"{instance_id}.traj.json"
        traj = _load_traj(traj_path)
        if not traj and instance_id not in preds:
            print(f"WARNING: no traj.json and not in preds.json, skipping: {instance_id}", file=sys.stderr)
            continue
        if not traj:
            print(f"WARNING: traj.json missing for {instance_id}, timing/token metrics will be 0", file=sys.stderr)

        info = traj.get("info", {})
        model_stats = info.get("model_stats", {})

        # wall-clock tracking
        inst_started = info.get("started_at")
        inst_completed = info.get("completed_at")
        if inst_started:
            wall_start = min(wall_start, inst_started) if wall_start else inst_started
        if inst_completed:
            wall_end = max(wall_end, inst_completed) if wall_end else inst_completed

        cost_usd: float = model_stats.get("instance_cost", 0.0)
        api_calls: int = model_stats.get("api_calls", 0)
        tokens: int = _get_tokens(traj)
        e2e_time, time_to_first_action = _get_timing(traj)

        exit_status: str = info.get("exit_status", "")
        patch: str = (preds.get(instance_id, {}).get("model_patch") or info.get("submission") or "")
        patch_generated = bool(patch.strip())

        if exit_status in ("submitted", "LimitsExceeded"):
            status, step1_status = "success", "success"
            success_count += 1
        else:
            status = "fail"
            step1_status = "error" if api_calls == 0 else "success"
            fail_count += 1

        # eval results
        report = _load_instance_report(eval_dir, args.run_id, instance_id)
        if not report and instance_id in resolved_ids:
            # resolved_ids says resolved but no report — treat as fully resolved
            print(f"WARNING: no report.json for {instance_id} but it is in resolved_ids", file=sys.stderr)
        ftp_total, ftp_passed, ptp_total, ptp_passed = _eval_counts(report)
        resolved = instance_id in resolved_ids or report.get("resolved", False)

        # fallback totals from dataset if eval didn't produce counts
        if ftp_total == 0 and ptp_total == 0 and instance_id in dataset_instances:
            inst_data = dataset_instances[instance_id]
            ftp_total = len(inst_data.get("FAIL_TO_PASS", []))
            ptp_total = len(inst_data.get("PASS_TO_PASS", []))

        if resolved:
            resolved_count += 1

        # eval detail relative path
        eval_detail = ""
        for report_file in eval_dir.rglob(f"{instance_id}/report.json"):
            try:
                eval_detail = str(report_file.relative_to(eval_dir.parent)).replace("\\", "/")
            except ValueError:
                eval_detail = str(report_file).replace("\\", "/")
            break

        model_used = preds.get(instance_id, {}).get("model_name_or_path", args.model_name)

        per_task.append({
            "instance_id": instance_id,
            "agent": args.agent_name,
            "status": status,
            "step1_status": step1_status,
            "patch_generated": patch_generated,
            "cost_usd": cost_usd,
            "e2e_time": e2e_time,
            "tokens": tokens,
            "convergence_steps": api_calls,
            "model": model_used,
            "resolved": resolved,
            "fail_to_pass_total": ftp_total,
            "fail_to_pass_passed": ftp_passed,
            "pass_to_pass_total": ptp_total,
            "pass_to_pass_passed": ptp_passed,
            "eval_detail": eval_detail,
        })

        all_costs.append(cost_usd)
        all_tokens.append(tokens)
        all_steps.append(api_calls)
        all_e2e.append(e2e_time)
        all_first_action.append(time_to_first_action)

    # --- aggregate metrics ---
    n = len(per_task)
    if n == 0:
        sys.exit("ERROR: no instances found")

    resolution_rate = resolved_count / n
    avg_tokens = sum(all_tokens) / n
    avg_e2e = sum(all_e2e) / n
    avg_first_action = sum(all_first_action) / n
    avg_steps = sum(all_steps) / n
    total_cost = sum(all_costs)
    cost_per_resolved = total_cost / resolved_count if resolved_count > 0 else 0.0

    # --- timestamps ---
    now = datetime.now(timezone.utc)
    fmt = "%Y-%m-%dT%H:%M:%S.%f"
    started_str = datetime.fromtimestamp(wall_start, timezone.utc).strftime(fmt) if wall_start else now.strftime(fmt)
    completed_str = datetime.fromtimestamp(wall_end, timezone.utc).strftime(fmt) if wall_end else now.strftime(fmt)

    # --- model name (from preds if not provided) ---
    model_name = args.model_name
    if not model_name and preds:
        model_name = next(iter(preds.values())).get("model_name_or_path", "")

    run_id = args.run_id

    summary = {
        "run_id": run_id,
        "agent": args.agent_name,
        "model": model_name,
        "tier": "lite",
        "num_tasks": n,
        "started_at": started_str,
        "completed_at": completed_str,
        "environment": _env_info(),
        "agents": {
            args.agent_name: {
                "metrics": {
                    "task_resolution_rate": {
                        "value": resolution_rate,
                        "unit": "%",
                        "grade": _grade("task_resolution_rate", resolution_rate),
                    },
                    "token_efficiency": {
                        "value": avg_tokens,
                        "unit": "tokens/task",
                        "grade": _grade("token_efficiency", avg_tokens),
                    },
                    "cost_per_resolved_task": {
                        "value": cost_per_resolved,
                        "unit": "USD",
                        "grade": _grade("cost_per_resolved_task", cost_per_resolved),
                    },
                    "e2e_time": {
                        "value": avg_e2e,
                        "unit": "sec",
                        "grade": _grade("e2e_time", avg_e2e),
                    },
                    "time_to_first_action": {
                        "value": avg_first_action,
                        "unit": "sec",
                        "grade": _grade("time_to_first_action", avg_first_action),
                    },
                    "convergence_steps": {
                        "value": avg_steps,
                        "unit": "steps",
                        "grade": _grade("convergence_steps", avg_steps),
                    },
                }
            }
        },
        "task_counts": {
            "success": success_count,
            "fail": fail_count,
            "error": 0,
            "resolved": resolved_count,
            "evaluable": n,
            "resolution_rate_pct": round(resolution_rate * 100, 1),
        },
        "failure_breakdown": {
            "by_category": {},
            "model_failures": 0,
            "infrastructure_failures": fail_count,
        },
        "per_task": per_task,
        "generated_at": now.strftime(fmt),
    }

    output_path = Path(args.output) if args.output else agent_dir / "summary.json"
    output_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"Summary written to: {output_path}")
    print(f"  Tasks     : {n}")
    print(f"  Resolved  : {resolved_count} / {n} ({resolution_rate * 100:.1f}%)")
    print(f"  Total cost: ${total_cost:.4f}")


if __name__ == "__main__":
    main()
