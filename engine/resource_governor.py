#!/usr/bin/env python3
"""Machine-aware resource governor for the dispatch loop.

Pure sizing logic plus the machine probes it needs (logical cores, currently
available memory, CPU busy fraction over a short window, 1-minute load
average). No third-party
dependencies, macOS and Linux. Every machine fact is injectable so the
callers' tests are hermetic, and a failed probe degrades to a safe answer
instead of raising: a reconcile cycle must never crash, or silently stop
dispatching, because `vm_stat` printed something unexpected.

Two separate questions are answered here and kept separate on purpose:

  1. CEILING  - how many workers may ever run at once on this machine.
     `auto` takes min(cpuSlots, memorySlots, diskSlots); an explicit integer
     keeps the pre-governor rule exactly (min(configured, diskSlots)).
  2. ADMISSION - may NEW workers/planners start in this cycle. Decided from
     live pressure (CPU busy fraction, or load per core when the CPU cannot be
     sampled; available memory) with hysteresis. It never changes the ceiling
     and never touches work that is already running.

`resource-plan.sh` is the only entry point; it owns disk measurement and
provider pressure and hands this module already-validated disk numbers.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time

SCHEMA = "singular.orchestration.resource-plan.v0"
STATE_SCHEMA = "singular.orchestration.resource-governor-state.v0"

GIB = 1024 ** 3

# --- Defaults (each overridable through resources{} / SINGULAR_* env) --------
#
# CPU. A worker is an agent CLI that spends most of its wall-clock waiting on a
# remote model, so one worker per logical core is affordable on average; the
# bursts are the gate runs. Two cores stay reserved for what is not a worker:
# the L0 loop itself (reconcile, git, integration, python helpers) and the
# operator's foreground. The hard cap exists because past ~8 concurrent agent
# sessions the bottleneck is no longer this machine: L0 imports and integrates
# serially and providers rate-limit, so more workers only add merge conflicts
# and 429s. On a 12-core host: min(8, (12 - 2) * 1) = 8.
DEFAULT_CPU_RESERVE_CORES = 2
DEFAULT_WORKERS_PER_CORE = 1.0
DEFAULT_AUTO_MAX_CONCURRENT = 8
# Memory. ~1 GiB per worker covers the agent CLI (a Node process, 300-500 MiB
# resident) plus one gate run. 2 GiB stays free so the host does not start
# swapping, which is what turns long planner/critic calls into timeouts.
DEFAULT_ESTIMATED_WORKER_BYTES = 1 * GIB
DEFAULT_MEMORY_RESERVE_BYTES = 2 * GIB
# Live pressure. Load per core above 1.5 means runnable work is queueing half
# again deeper than the cores can serve; admission resumes at 1.0 (exactly
# saturated). The gap is the hysteresis: the 1-minute average decays slowly,
# so a single threshold would flap on every cycle. These marks are a
# backstop, not the primary control - the ceiling above is. Note the field
# incident that motivated this (load 13 on 12 cores, other heavy processes
# present) peaked at ~1.08 per core: a host that shares its cores like that
# should lower both marks (for example 1.0 / 0.75).
DEFAULT_LOAD_HIGH_WATER = 1.5
DEFAULT_LOAD_LOW_WATER = 1.0
# CPU busy fraction (0.23.7): the primary pressure signal. The load average
# counts threads blocked on I/O and lags by a minute; on a 12-core macOS host
# it read 15-30 while the CPU was 55% idle (the governor throttled an idle
# machine) and 30 with the CPU 0% idle (where throttling was right). Busy
# fraction over a short window separates the two. Admission stops above 0.90
# and resumes below 0.75; load per core remains the fallback signal when the
# CPU cannot be sampled.
DEFAULT_CPU_BUSY_HIGH_WATER = 0.90
DEFAULT_CPU_BUSY_LOW_WATER = 0.75
DEFAULT_CPU_SAMPLE_SEC = 1.0
# A read-only caller (health, doctor) reuses the loop's last sample when it is
# this fresh instead of spending another sampling window.
CPU_SAMPLE_REUSE_SEC = 30
# Planners are long read-mostly model calls; half the worker ceiling keeps the
# queue fed without planners crowding out the workers they plan for.
DEFAULT_PLANNER_FRACTION = 0.5
# What `auto` degrades to when the machine cannot be measured: the default
# resource-plan.sh shipped with before the governor existed.
PROBE_FALLBACK_SLOTS = 3


# --- Parsing helpers ---------------------------------------------------------

def parse_positive_int(raw):
    """A strictly positive integer, or None for anything else."""
    if raw is None or isinstance(raw, bool):
        return None
    text = str(raw).strip()
    if not re.fullmatch(r"[0-9]+", text):
        return None
    value = int(text)
    return value if value >= 1 else None


def parse_non_negative_int(raw):
    if raw is None or isinstance(raw, bool):
        return None
    text = str(raw).strip()
    if not re.fullmatch(r"[0-9]+", text):
        return None
    return int(text)


def parse_non_negative_float(raw):
    if raw is None or isinstance(raw, bool):
        return None
    text = str(raw).strip()
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)?|\.[0-9]+", text):
        return None
    value = float(text)
    return value if math.isfinite(value) else None


def setting_int(env, name, default, *, minimum=0):
    value = parse_non_negative_int(env.get(name))
    return default if value is None or value < minimum else value


def setting_float(env, name, default, *, minimum=0.0):
    value = parse_non_negative_float(env.get(name))
    return default if value is None or value < minimum else value


# --- Probes ------------------------------------------------------------------
# Each returns None when the fact is unavailable. Never raises.

def probe_cpu_count():
    try:
        count = os.cpu_count()
    except Exception:  # pragma: no cover - defensive
        return None
    return count if isinstance(count, int) and count >= 1 else None


def parse_vm_stat(text):
    """Available bytes from macOS `vm_stat` output, or None.

    free + inactive + speculative + purgeable: the pages the kernel can hand
    out without swapping or compressing. Wired, active and compressor-occupied
    pages are deliberately not counted.
    """
    match = re.search(r"page size of (\d+) bytes", text)
    if not match:
        return None
    page_size = int(match.group(1))
    wanted = ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable")
    pages = 0
    seen = 0
    for label in wanted:
        row = re.search(r"^" + re.escape(label) + r":\s+(\d+)\.?\s*$", text, re.MULTILINE)
        if row:
            pages += int(row.group(1))
            seen += 1
    # "Pages free" alone would under-report badly; require the two that
    # dominate on every macOS release before trusting the sum.
    if seen < 2 or not re.search(r"^Pages free:", text, re.MULTILINE):
        return None
    return pages * page_size


def parse_meminfo(text):
    """Available bytes from Linux /proc/meminfo, or None."""
    match = re.search(r"^MemAvailable:\s+(\d+)\s*kB\s*$", text, re.MULTILINE)
    if not match:
        return None
    return int(match.group(1)) * 1024


def probe_available_memory():
    try:
        if sys.platform.startswith("linux"):
            with open("/proc/meminfo", "r", encoding="utf-8", errors="replace") as handle:
                return parse_meminfo(handle.read())
        if sys.platform == "darwin":
            result = subprocess.run(
                ["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=5, check=False
            )
            if result.returncode != 0:
                return None
            return parse_vm_stat(result.stdout)
    except Exception:
        return None
    return None


def parse_fraction(raw):
    """A fraction in [0, 1], or None."""
    value = parse_non_negative_float(raw)
    if value is None or value > 1.0:
        return None
    return value


def parse_top_cpu_usage(text):
    """Busy fraction from the LAST `CPU usage:` line of macOS `top -l N`, or None.

    The first sample of `top -l` is the average since boot; only a later
    sample describes the window. Callers pass `-l 2` and this reads the last.
    """
    rows = re.findall(r"^CPU usage:.*?([0-9]+(?:\.[0-9]+)?)%\s*idle", text, re.MULTILINE)
    if len(rows) < 2:
        return None
    idle = float(rows[-1])
    if not math.isfinite(idle) or idle < 0 or idle > 100:
        return None
    return round(1.0 - idle / 100.0, 4)


def parse_proc_stat(text):
    """(idle jiffies, total jiffies) from the aggregate `cpu` line of /proc/stat.

    iowait counts as idle: a core waiting on a disk is not a busy core, which
    is exactly the distinction the load average cannot make.
    """
    match = re.search(r"^cpu\s+(.+)$", text, re.MULTILINE)
    if not match:
        return None
    try:
        fields = [int(part) for part in match.group(1).split()]
    except ValueError:
        return None
    if len(fields) < 4:
        return None
    idle = fields[3] + (fields[4] if len(fields) > 4 else 0)
    total = sum(fields[:8]) if len(fields) >= 8 else sum(fields)
    return (idle, total) if total > 0 else None


def cpu_busy_between(first, second):
    """Busy fraction between two parse_proc_stat samples, or None."""
    if not first or not second:
        return None
    total = second[1] - first[1]
    idle = second[0] - first[0]
    if total <= 0 or idle < 0 or idle > total:
        return None
    return round(1.0 - idle / total, 4)


def probe_cpu_busy(window=DEFAULT_CPU_SAMPLE_SEC):
    """CPU busy fraction over `window` seconds, or None. Never raises."""
    try:
        if sys.platform.startswith("linux"):
            with open("/proc/stat", "r", encoding="utf-8", errors="replace") as handle:
                first = parse_proc_stat(handle.read())
            time.sleep(max(0.1, float(window)))
            with open("/proc/stat", "r", encoding="utf-8", errors="replace") as handle:
                second = parse_proc_stat(handle.read())
            return cpu_busy_between(first, second)
        if sys.platform == "darwin":
            delay = max(1, int(round(float(window))))
            result = subprocess.run(
                ["/usr/bin/top", "-l", "2", "-n", "0", "-s", str(delay)],
                capture_output=True, text=True, timeout=delay + 10, check=False,
            )
            if result.returncode != 0:
                return None
            return parse_top_cpu_usage(result.stdout)
    except Exception:
        return None
    return None


def probe_load_1m():
    try:
        value = os.getloadavg()[0]
    except Exception:
        return None
    return value if math.isfinite(value) and value >= 0 else None


def resolve_fact(flag_value, env, env_name, parser, probe):
    """(value, source). Injected value wins; garbage is 'unavailable', never a probe.

    An injected value that does not parse must NOT silently fall through to the
    real machine: the caller asked for a specific fact and got it wrong, and a
    test that injects garbage is asking what happens when the probe is broken.
    """
    for raw, source in ((flag_value, "flag"), (env.get(env_name), "env")):
        if raw is None or str(raw) == "":
            continue
        value = parser(raw)
        return (value, source) if value is not None else (None, source + "-invalid")
    value = probe()
    return (value, "probe") if value is not None else (None, "probe-failed")


# --- Throttle state (hysteresis memory) --------------------------------------

def read_state(path):
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(doc, dict) or doc.get("schema") != STATE_SCHEMA:
        return {}
    return doc


def write_state(path, doc):
    """Atomic best-effort write. A read-only state dir must not fail the plan."""
    try:
        directory = os.path.dirname(path) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".resource-governor.", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(doc, handle, separators=(",", ":"))
                handle.write("\n")
            os.replace(tmp, path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except Exception:
        return False
    return True


# --- The plan ----------------------------------------------------------------

def compute_plan(
    *,
    configured,          # "auto" or a non-negative int
    free_bytes,
    reserve_bytes,
    estimated_worktree_bytes,
    cpu_count,           # int or None
    available_memory,    # int or None
    load_1m,             # float or None
    active_workers,
    settings,
    previous_state,
    active_planners=0,
    cpu_busy=None,           # float in [0, 1] or None
    cpu_busy_probe_failed=False,
):
    affordable = max(0, free_bytes - reserve_bytes) // estimated_worktree_bytes
    disk_slots = affordable

    probe_failures = []
    if cpu_count is None:
        probe_failures.append("cpu")
    if available_memory is None:
        probe_failures.append("memory")
    if load_1m is None:
        probe_failures.append("load")
    if cpu_busy is None and cpu_busy_probe_failed:
        probe_failures.append("cpu-busy")

    cpu_slots = None
    if cpu_count is not None:
        usable = max(0, cpu_count - settings["cpuReserveCores"])
        cpu_slots = int(math.floor(usable * settings["workersPerCore"]))
        cpu_slots = max(1, min(cpu_slots, settings["autoMaxConcurrent"]))

    memory_slots = None
    if available_memory is not None:
        # Available memory is measured with the active workers already
        # running, so their footprint is already subtracted from it. The
        # ceiling is therefore "what is running" plus "what still fits";
        # without the first term a healthy, busy machine would see its ceiling
        # shrink below its own active count and never refill a freed slot.
        headroom = max(0, available_memory - settings["memoryReserveBytes"])
        memory_slots = max(1, active_workers + headroom // settings["estimatedWorkerBytes"])

    if configured == "auto":
        mode = "auto"
        if cpu_slots is None or memory_slots is None:
            # Never zero because a probe failed: fall back to the old default.
            machine = PROBE_FALLBACK_SLOTS
            effective = min(machine, disk_slots)
            reason = "probe-unavailable" if effective == machine else "disk-bound"
        else:
            machine = min(cpu_slots, memory_slots)
            effective = min(machine, disk_slots)
            if effective < machine:
                reason = "disk-bound"
            elif memory_slots < cpu_slots:
                reason = "memory-bound"
            else:
                reason = "cpu-bound"
        configured_slots = machine
    else:
        # Explicit integer: the pre-governor rule and its reason vocabulary,
        # unchanged. CPU and memory slots are still reported (doctor compares
        # them with the explicit number) but do not lower the ceiling.
        mode = "explicit"
        configured_slots = int(configured)
        effective = min(configured_slots, disk_slots)
        if effective == configured_slots:
            reason = "configured-capacity-available"
        elif effective == 0:
            reason = "insufficient-disk-after-reserve"
        else:
            reason = "disk-limited-concurrency"

    # -- admission (live pressure, hysteresis) --
    load_per_core = None
    if load_1m is not None and cpu_count is not None:
        load_per_core = round(load_1m / cpu_count, 3)

    was = (
        previous_state.get("admissionReason")
        if previous_state.get("admission") in ("throttled", "floor")
        else None
    )
    admission_reason = None
    # Which machine-pressure signal decided: CPU busy fraction when it could be
    # measured, load per core only as the fallback. A hold taken on one signal
    # is released by the other's low-water mark, so switching signals between
    # cycles can never strand a throttle.
    pressure_signal = "none"
    was_pressure = was in ("cpu-busy", "load-high")
    if settings["throttle"]:
        high, low = settings["loadHighWater"], settings["loadLowWater"]
        busy_high, busy_low = settings["cpuBusyHighWater"], settings["cpuBusyLowWater"]
        if cpu_busy is not None:
            pressure_signal = "cpu-busy"
            if cpu_busy > busy_high or (was_pressure and cpu_busy > busy_low):
                admission_reason = "cpu-busy"
        elif load_per_core is not None:
            pressure_signal = "load-average"
            if load_per_core > high or (was_pressure and load_per_core > low):
                admission_reason = "load-high"
        if admission_reason is None and available_memory is not None:
            floor = settings["memoryReserveBytes"]
            # Resume only once one more worker actually fits above the reserve.
            resume_at = floor + settings["estimatedWorkerBytes"]
            if available_memory < floor or (was == "memory-low" and available_memory < resume_at):
                admission_reason = "memory-low"
    admission = "throttled" if admission_reason else "open"

    # Minimum-progress floor. A host that is saturated by OTHER processes
    # never falls back under the low-water mark, so a strict hold would stop
    # the loop for good while it contributes nothing to the load it is waiting
    # out. When the hold would apply and this loop has nothing running at all
    # (no worker, no planner), exactly one unit of work is admitted. As soon
    # as anything of ours is running the hold is strict again, so the floor
    # can never stack: it is one unit at a time, not one extra per cycle.
    progress_floor = bool(
        admission_reason
        and settings["progressFloor"] >= 1
        and effective > 0
        and active_workers == 0
        and active_planners == 0
    )
    if progress_floor:
        admission = "floor"

    capacity_reason = reason
    if admission_reason and effective > 0:
        # Disk exhaustion (effective == 0) keeps its own reason: that state has
        # its own degraded mode and exit condition in reconcile.
        reason = admission_reason + ("-floor" if progress_floor else "")

    if effective <= 0:
        planner_slots = 0
    else:
        planner_slots = max(1, min(effective, int(math.ceil(effective * settings["plannerFraction"]))))

    record = {
        # The first eight keys are the pre-governor record, same names, same
        # order. Everything after them is additive.
        "schema": SCHEMA,
        "configuredSlots": configured_slots,
        "effectiveSlots": effective,
        "freeBytes": free_bytes,
        "reserveBytes": reserve_bytes,
        "estimatedWorktreeBytes": estimated_worktree_bytes,
        "affordableSlots": affordable,
        "reason": reason,
        "mode": mode,
        "capacityReason": capacity_reason,
        "cpuSlots": cpu_slots,
        "memorySlots": memory_slots,
        "diskSlots": disk_slots,
        "plannerSlots": planner_slots,
        "plannerFraction": settings["plannerFraction"],
        "cpuCount": cpu_count,
        "loadAverage1m": None if load_1m is None else round(load_1m, 3),
        "loadPerCore": load_per_core,
        "availableMemoryBytes": available_memory,
        "estimatedWorkerBytes": settings["estimatedWorkerBytes"],
        "memoryReserveBytes": settings["memoryReserveBytes"],
        "activeWorkers": active_workers,
        "activePlanners": active_planners,
        "admission": admission,
        "admissionReason": admission_reason,
        "progressFloor": progress_floor,
        "loadHighWater": settings["loadHighWater"],
        "loadLowWater": settings["loadLowWater"],
        "probeFailures": probe_failures,
        "cpuBusy": None if cpu_busy is None else round(cpu_busy, 3),
        "cpuBusyHighWater": settings["cpuBusyHighWater"],
        "cpuBusyLowWater": settings["cpuBusyLowWater"],
        "pressureSignal": pressure_signal,
    }
    return record


def load_settings(env):
    high = setting_float(env, "SINGULAR_LOAD_HIGH_WATER", DEFAULT_LOAD_HIGH_WATER, minimum=0.01)
    low = setting_float(env, "SINGULAR_LOAD_LOW_WATER", DEFAULT_LOAD_LOW_WATER, minimum=0.0)
    if low > high:
        low = high
    fraction = setting_float(env, "SINGULAR_L1_AUTO_FRACTION", DEFAULT_PLANNER_FRACTION, minimum=0.01)
    busy_high = parse_fraction(env.get("SINGULAR_CPU_BUSY_HIGH_WATER"))
    if busy_high is None or busy_high < 0.01:
        busy_high = DEFAULT_CPU_BUSY_HIGH_WATER
    busy_low = parse_fraction(env.get("SINGULAR_CPU_BUSY_LOW_WATER"))
    if busy_low is None:
        busy_low = DEFAULT_CPU_BUSY_LOW_WATER
    if busy_low > busy_high:
        busy_low = busy_high
    return {
        "cpuBusyHighWater": busy_high,
        "cpuBusyLowWater": busy_low,
        "cpuSampleSeconds": setting_float(env, "SINGULAR_CPU_SAMPLE_SEC", DEFAULT_CPU_SAMPLE_SEC),
        "cpuReserveCores": setting_int(env, "SINGULAR_CPU_RESERVE_CORES", DEFAULT_CPU_RESERVE_CORES),
        "workersPerCore": setting_float(env, "SINGULAR_WORKERS_PER_CORE", DEFAULT_WORKERS_PER_CORE, minimum=0.01),
        "autoMaxConcurrent": setting_int(env, "SINGULAR_AUTO_MAX_CONCURRENT", DEFAULT_AUTO_MAX_CONCURRENT, minimum=1),
        "estimatedWorkerBytes": setting_int(env, "SINGULAR_ESTIMATED_WORKER_BYTES", DEFAULT_ESTIMATED_WORKER_BYTES, minimum=1),
        "memoryReserveBytes": setting_int(env, "SINGULAR_MEMORY_RESERVE_BYTES", DEFAULT_MEMORY_RESERVE_BYTES),
        "loadHighWater": high,
        "loadLowWater": low,
        "plannerFraction": min(1.0, fraction),
        "progressFloor": setting_int(env, "SINGULAR_PROGRESS_FLOOR", 1),
        "throttle": str(env.get("SINGULAR_RESOURCE_THROTTLE", "1")).strip().lower() not in ("0", "false", "off", "no"),
    }


def event_view(path):
    """Four lines for reconcile.sh from a stored plan: admission, admission
    reason, planner slots, and the governor fields as a JSON object body
    (no braces) ready to splice into the origin.resource_plan payload.
    Tolerates a missing, unreadable or pre-governor plan."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            plan = json.load(handle)
    except (OSError, ValueError):
        plan = {}
    if not isinstance(plan, dict):
        plan = {}

    def number(key):
        value = plan.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return value

    admission = plan.get("admission") if plan.get("admission") in ("open", "throttled", "floor") else "open"
    reason = (
        plan.get("admissionReason")
        if plan.get("admissionReason") in ("cpu-busy", "load-high", "memory-low") else ""
    )
    planner = plan.get("plannerSlots")
    planner = planner if isinstance(planner, int) and not isinstance(planner, bool) and planner >= 0 else ""
    fragment = {key: number(key) for key in (
        "cpuSlots", "memorySlots", "diskSlots", "loadPerCore", "availableMemoryBytes", "cpuBusy")}
    fragment["pressureSignal"] = (
        plan.get("pressureSignal")
        if plan.get("pressureSignal") in ("cpu-busy", "load-average") else "none"
    )
    fragment["mode"] = plan.get("mode") if plan.get("mode") in ("auto", "explicit") else "explicit"
    fragment["admission"] = admission
    fragment["progressFloor"] = plan.get("progressFloor") is True
    print(admission)
    print(reason)
    print(planner)
    print(json.dumps(fragment, separators=(",", ":"))[1:-1])
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) == 2 and argv[0] == "--event-view":
        return event_view(argv[1])
    parser = argparse.ArgumentParser(prog="resource_governor.py")
    parser.add_argument("--configured", required=True)
    parser.add_argument("--free-bytes", required=True, type=int)
    parser.add_argument("--reserve-bytes", required=True, type=int)
    parser.add_argument("--estimated-worktree-bytes", required=True, type=int)
    parser.add_argument("--cpu-count")
    parser.add_argument("--available-memory-bytes")
    parser.add_argument("--load-1m")
    parser.add_argument("--cpu-busy", help="CPU busy fraction in [0,1]; injected instead of sampled")
    parser.add_argument("--active-workers", default="0")
    parser.add_argument("--active-planners", default="0")
    parser.add_argument("--state-file", default="")
    parser.add_argument("--update-state", action="store_true")
    args = parser.parse_args(argv)

    env = os.environ
    configured_raw = str(args.configured).strip().lower()
    if configured_raw == "auto":
        configured = "auto"
    else:
        configured = parse_non_negative_int(configured_raw)
        if configured is None:
            sys.stderr.write("resource-governor: configured slots must be 'auto' or a non-negative integer\n")
            return 2
    if args.estimated_worktree_bytes <= 0 or args.free_bytes < 0 or args.reserve_bytes < 0:
        sys.stderr.write("resource-governor: invalid disk arguments\n")
        return 2

    cpu_count, _ = resolve_fact(args.cpu_count, env, "SINGULAR_RESOURCE_CPU_COUNT", parse_positive_int, probe_cpu_count)
    available_memory, _ = resolve_fact(
        args.available_memory_bytes, env, "SINGULAR_RESOURCE_AVAILABLE_MEMORY_BYTES",
        parse_non_negative_int, probe_available_memory,
    )
    load_1m, load_source = resolve_fact(
        args.load_1m, env, "SINGULAR_RESOURCE_LOAD_1M", parse_non_negative_float, probe_load_1m
    )
    active_workers = parse_non_negative_int(args.active_workers) or 0
    active_planners = parse_non_negative_int(args.active_planners) or 0

    settings = load_settings(env)
    previous = read_state(args.state_file)

    # CPU busy fraction. Injected (flag or SINGULAR_RESOURCE_CPU_BUSY) wins and
    # garbage is "unavailable", like every other fact. When the caller injected
    # the LOAD instead, it is specifying the pressure signal itself: the real
    # CPU is not sampled, so hermetic callers stay hermetic and fast. Sampling
    # can also be turned off (SINGULAR_CPU_SAMPLE_SEC=0). Otherwise sample - or,
    # for a read-only caller, reuse the loop's sample when it is fresh.
    cpu_busy = None
    cpu_busy_probe_failed = False
    cpu_busy_injected = False
    for raw in (args.cpu_busy, env.get("SINGULAR_RESOURCE_CPU_BUSY")):
        if raw is None or str(raw) == "":
            continue
        cpu_busy_injected = True
        cpu_busy = parse_fraction(raw)
        cpu_busy_probe_failed = cpu_busy is None
        break
    if (
        not cpu_busy_injected
        and settings["throttle"]
        and settings["cpuSampleSeconds"] > 0
        and load_source not in ("flag", "env", "flag-invalid", "env-invalid")
    ):
        reused = None
        if not args.update_state:
            stamp = previous.get("cpuBusyAt")
            stored = previous.get("cpuBusy")
            if (
                isinstance(stamp, (int, float)) and not isinstance(stamp, bool)
                and isinstance(stored, (int, float)) and not isinstance(stored, bool)
                and 0 <= time.time() - stamp <= CPU_SAMPLE_REUSE_SEC and 0 <= stored <= 1
            ):
                reused = float(stored)
        cpu_busy = reused if reused is not None else probe_cpu_busy(settings["cpuSampleSeconds"])
        cpu_busy_probe_failed = cpu_busy is None
    record = compute_plan(
        configured=configured,
        free_bytes=args.free_bytes,
        reserve_bytes=args.reserve_bytes,
        estimated_worktree_bytes=args.estimated_worktree_bytes,
        cpu_count=cpu_count,
        available_memory=available_memory,
        load_1m=load_1m,
        active_workers=active_workers,
        active_planners=active_planners,
        settings=settings,
        previous_state=previous,
        cpu_busy=cpu_busy,
        cpu_busy_probe_failed=cpu_busy_probe_failed,
    )
    if args.update_state and args.state_file:
        changed = (
            previous.get("admission") != record["admission"]
            or previous.get("admissionReason") != record["admissionReason"]
        )
        write_state(args.state_file, {
            "schema": STATE_SCHEMA,
            "admission": record["admission"],
            "admissionReason": record["admissionReason"],
            "since": int(time.time()) if changed or "since" not in previous else previous.get("since"),
            "loadPerCore": record["loadPerCore"],
            "cpuBusy": record["cpuBusy"],
            "cpuBusyAt": int(time.time()) if record["cpuBusy"] is not None else None,
            "pressureSignal": record["pressureSignal"],
            "availableMemoryBytes": record["availableMemoryBytes"],
            # The measured ceiling, for callers that need a number when the
            # request is `auto` (provider-pressure baseline).
            "mode": record["mode"],
            "configuredSlots": record["configuredSlots"],
        })
    print(json.dumps(record, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
