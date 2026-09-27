#!/usr/bin/env bash
# Reproduces every quantitative claim in "What a Bounded Blast Radius Still Lets Through."
# https://revisualized.com/articles/what-a-bounded-blast-radius-still-lets-through
# Each numbered section is a separate demonstration block. Directories are created
# with mktemp under distinctive, brand-prefixed names and removed on exit
# via trap, so nothing is left behind and nothing collides with another run.
set -euo pipefail;

# Every sandbox any section creates gets registered here and removed by one
# trap at actual script exit, rather than each section setting and clearing
# its own trap. This reduces the unregistered-directory window to a single
# line, the gap between mktemp returning and the very next register_sandbox
# call, rather than the gap between mktemp and a later per-section trap
# statement; it does not remove that window, since a kill between those two
# lines still orphans a directory, but it is smaller and simpler than what
# it replaces.
SANDBOXES=();
cleanup_all() {
  local d;
  for d in "${SANDBOXES[@]:-}"; do
    if [ -n "$d" ]; then
      rm -rf -- "$d";
    fi;
  done;
};
trap cleanup_all EXIT;

register_sandbox() {
  SANDBOXES+=("$1");
};

require_cmd() {
  command -v "$1" > /dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; };
};

echo "==================================================";
echo "0. Preflight: required commands, environment, and uid 65534";
echo "==================================================";
for cmd in python3 find xargs sort tr sha256sum mktemp mv seq wc cut head rm chmod chown mkdir touch id uname getent stat bash; do
  require_cmd "$cmd";
done;
echo "all core commands found: python3 find xargs sort tr sha256sum mktemp mv seq wc cut head rm chmod chown mkdir touch id uname getent stat bash";

# Section 3 calls Executor.shutdown(cancel_futures=...), added in Python 3.9;
# on 3.8 or earlier this fails with a TypeError partway through the run
# instead of at this preflight check. Caught here instead.
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)" || {
  echo "ERROR: Python 3.9 or newer required (section 3 uses Executor.shutdown(cancel_futures=...), added in 3.9); found $(python3 --version 2>&1)" >&2;
  exit 1;
};

if command -v findmnt > /dev/null 2>&1; then
  FINDMNT_AVAILABLE=1;
else
  FINDMNT_AVAILABLE=0;
  echo "note: findmnt not found; section 4 will run but skip printing the filesystem type.";
fi;

if command -v setpriv > /dev/null 2>&1; then
  SETPRIV_AVAILABLE=1;
else
  SETPRIV_AVAILABLE=0;
  echo "note: setpriv not found; section 7 will be skipped even if run as root.";
fi;

echo;
echo "user: $(id)";
echo "kernel: $(uname -sr)";
printf 'python3: '; python3 --version;
printf 'find: ';
# --version prints the version and walks no path, so the missing path SC2185
# asks for would be meaningless here.
# shellcheck disable=SC2185
find --version | head -1;
printf 'mv: '; mv --version | head -1;
if [ "$FINDMNT_AVAILABLE" -eq 1 ]; then
  printf 'findmnt: '; findmnt --version | head -1;
fi;
if [ "$SETPRIV_AVAILABLE" -eq 1 ]; then
  printf 'setpriv: '; setpriv --version;
fi;

echo;
echo "uid/gid 65534, used in section 7:";
getent passwd 65534 || echo "  no passwd entry for 65534 on this system (fine, setpriv accepts a bare numeric uid directly; the name assigned to 65534, if any, varies by distribution and version)";
getent group 65534 || echo "  no group entry for 65534 on this system (fine, same reason)";

echo "==================================================";
echo "1. Cap test: the collapse itself, then normal vs. collapsed-path counts";
echo "why this matters: a count alone can't tell you whether it counted the right things";
echo "==================================================";
DEMO_ROOT="$(mktemp -d /tmp/revisualized_blast_radius_cap_test.XXXXXX)";
register_sandbox "$DEMO_ROOT";
# Build the intended target under a real (sandboxed) DATA_DIR, and a
# stand-in for what the real filesystem root would hold, since this script
# never touches the actual /. The stand-in's collapsed path is not just a
# same-named parallel directory: it is built by literally concatenating the
# real computed collapse result onto the stand-in root, so the path used
# for counting is mechanically derived from the actual expansion, not
# merely labeled to look like it.
DATA_DIR="$DEMO_ROOT/srv/app/data";
mkdir -p "$DATA_DIR/current_run/a" "$DATA_DIR/current_run/b" "$DATA_DIR/current_run/c" "$DATA_DIR/current_run/d" "$DATA_DIR/current_run/e";
for d in a b c d e; do
  for i in $(seq 1 1000); do : > "$DATA_DIR/current_run/$d/file_$i.dat"; done;
done;
FAKE_ROOT="$DEMO_ROOT/stand_in_for_real_root";
COLLAPSED_PATH="$(bash -c 'set +u; unset DATA_DIR; echo "${DATA_DIR}/current_run"')";
SANDBOX_COLLAPSED="${FAKE_ROOT}${COLLAPSED_PATH}";
mkdir -p "$SANDBOX_COLLAPSED/x" "$SANDBOX_COLLAPSED/y" "$SANDBOX_COLLAPSED/z";
for d in x y z; do
  for i in $(seq 1 2500); do : > "$SANDBOX_COLLAPSED/$d/entry_$i.dat"; done;
done;
(
  set +u;
  echo "DATA_DIR correctly set,   \${DATA_DIR}/current_run resolves to: $DATA_DIR/current_run";
  unset DATA_DIR;
  echo "DATA_DIR unset (empty),   \${DATA_DIR}/current_run resolves to: ${DATA_DIR}/current_run   (a path directly beneath the filesystem root)";
);
echo "-- this script never touches the real /; the collapsed path below is that same result, concatenated onto a sandbox root --";
echo "collapsed expansion: $COLLAPSED_PATH   ->   sandbox representation: $SANDBOX_COLLAPSED";
echo "-- the same unset case, under set -u, in a fresh subshell --";
bash -c 'set -u; unset DATA_DIR; echo "${DATA_DIR}/current_run"' 2>&1 || echo "(aborted: set -u caught it, exactly as intended)";
echo "-- set -u does NOT catch an empty-but-assigned variable --";
bash -c 'set -u; DATA_DIR=""; echo "resolves to: ${DATA_DIR}/current_run"';
CAP=10000;
normal_count=$(find "$DATA_DIR/current_run" -maxdepth 2 -type f -print0 | tr -cd '\0' | wc -c);
collapsed_count=$(find "$SANDBOX_COLLAPSED" -maxdepth 2 -type f -print0 | tr -cd '\0' | wc -c);
echo "normal run       (\$DATA_DIR/current_run)        candidate count: $normal_count   cap of $CAP -> $( [ "$normal_count" -gt "$CAP" ] && echo REFUSE || echo PROCEED )";
echo "collapsed path   (derived sandbox path above)   candidate count: $collapsed_count   cap of $CAP -> $( [ "$collapsed_count" -gt "$CAP" ] && echo REFUSE || echo PROCEED )";
# The section's point requires both counts to land under the cap despite
# being very different sizes; assert that rather than only printing it.
if [ "$normal_count" -ne 5000 ] || [ "$collapsed_count" -ne 7500 ]; then
  echo "ERROR: expected candidate counts 5000 and 7500 from the fixed test tree, got $normal_count and $collapsed_count" >&2;
  exit 1;
fi;
if [ "$normal_count" -gt "$CAP" ] || [ "$collapsed_count" -gt "$CAP" ]; then
  echo "ERROR: section 1's finding requires both counts to PROCEED under the cap; at least one did not" >&2;
  exit 1;
fi;

echo;
echo "==================================================";
echo "2. Extent: glob vs. find, dotfile visibility, no ls in the pipeline";
echo "why this matters: a review counting one way and a job running another way are looking at different target sets";
echo "==================================================";
GLOB_DEMO="$(mktemp -d /tmp/revisualized_blast_radius_glob_vs_find.XXXXXX)";
register_sandbox "$GLOB_DEMO";
mkdir -p "$GLOB_DEMO/d";
touch "$GLOB_DEMO/d/.hidden1" "$GLOB_DEMO/d/.hidden2" "$GLOB_DEMO/d/visible1" "$GLOB_DEMO/d/visible2";
cd "$GLOB_DEMO";
find_count=$(find d -mindepth 1 -print0 | tr -cd '\0' | wc -c);
echo "total entries via find (null-safe count): $find_count";
# Array expansion, not `ls | wc -l`: ls output parsing is a known landmine
# on filenames with spaces or newlines, avoided entirely here.
glob_matches=(d/*);
echo "glob d/* matches (array expansion, no ls): ${#glob_matches[@]}";
if [ "$find_count" -ne 4 ] || [ "${#glob_matches[@]}" -ne 2 ]; then
  echo "ERROR: expected find=4 glob=2 from the fixed 4-file, 2-dotfile tree, got find=$find_count glob=${#glob_matches[@]}" >&2;
  cd - > /dev/null;
  exit 1;
fi;
cd - > /dev/null;

echo;
echo "==================================================";
echo "3. Rate: completed, in progress, and queued at a fixed observation deadline";
echo "why this matters: what a stop can still prevent depends on how much work has already started, not on how much exists";
echo "==================================================";
# This observes state at 400ms, it does not send an interrupt signal to
# already-running work, Python threads cannot be force-killed mid-sleep.
# Reports three states, not two, since "not yet complete" silently
# conflated "already running" with "never started" in an earlier version.
python3 - << 'PY'
import concurrent.futures, time, threading

lock = threading.Lock()

def work(i, start_times, done_times):
    with lock:
        start_times[i] = time.monotonic()
    time.sleep(0.25)
    with lock:
        done_times[i] = time.monotonic()

print(f"{'P':<5}{'completed':<12}{'in_progress':<14}{'queued'}")
for P in [1, 4, 10, 40]:
    start_times, done_times = {}, {}
    t0 = time.monotonic()
    ex = concurrent.futures.ThreadPoolExecutor(max_workers=P)
    futures = [ex.submit(work, i, start_times, done_times) for i in range(40)]
    concurrent.futures.wait(futures, timeout=0.4)
    started = sum(1 for i in range(40) if i in start_times and start_times[i] - t0 < 0.4)
    completed = sum(1 for i in range(40) if i in done_times and done_times[i] - t0 < 0.4)
    in_progress = started - completed
    queued = 40 - started
    assert completed + in_progress + queued == 40, "the three states must account for all 40 targets"
    print(f"{P:<5}{completed:<12}{in_progress:<14}{queued}")
    ex.shutdown(wait=False, cancel_futures=True)
    time.sleep(0.3)
PY

echo;
echo "==================================================";
echo "4. Reversibility: rename vs. recursive delete, 5000 files";
echo "why this matters: two operations that look similar can differ enormously in whether you can undo them";
echo "==================================================";
REV_SOURCE="$(mktemp -d /tmp/revisualized_blast_radius_reversibility_source.XXXXXX)";
QUARANTINE_PARENT="$(mktemp -d /tmp/revisualized_blast_radius_reversibility_quarantine.XXXXXX)";
REV_QUARANTINE="$QUARANTINE_PARENT/quarantined";
register_sandbox "$REV_SOURCE";
register_sandbox "$QUARANTINE_PARENT";
for i in $(seq 1 5000); do echo "content-$i-$RANDOM" > "$REV_SOURCE/file_$i.dat"; done;
SOURCE_DEV="$(stat -c '%d' "$REV_SOURCE")";
QUARANTINE_DEV="$(stat -c '%d' "$QUARANTINE_PARENT")";
if [ "$FINDMNT_AVAILABLE" -eq 1 ]; then
  echo "environment: $(uname -sr), $(mv --version | head -1), filesystem: $(findmnt -T "$REV_SOURCE" -no FSTYPE)";
else
  echo "environment: $(uname -sr), $(mv --version | head -1), filesystem: unknown (findmnt not found)";
fi;
echo "source device id:      $SOURCE_DEV";
echo "quarantine device id:  $QUARANTINE_DEV";
if [ "$SOURCE_DEV" != "$QUARANTINE_DEV" ]; then
  echo "ERROR: source and quarantine are on different filesystems; the same-filesystem timing claim below does not hold on this run" >&2;
  exit 1;
fi;
BEFORE_MANIFEST="$(cd "$REV_SOURCE" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)";
echo "manifest before (content-hashed, beyond names/sizes): $BEFORE_MANIFEST";
TIMEFORMAT='%3R s';
time mv "$REV_SOURCE" "$REV_QUARANTINE";
echo "-- round trip: rename back, then check the manifest, not just assert it --";
time mv "$REV_QUARANTINE" "$REV_SOURCE";
AFTER_MANIFEST="$(cd "$REV_SOURCE" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)";
echo "manifest after:  $AFTER_MANIFEST   match: $( [ "$BEFORE_MANIFEST" = "$AFTER_MANIFEST" ] && echo yes || echo no )";
if [ "$BEFORE_MANIFEST" != "$AFTER_MANIFEST" ]; then
  echo "ERROR: manifest mismatch after the round trip; the reversibility claim this section makes does not hold on this run" >&2;
  exit 1;
fi;
echo "-- now the operation with no inverse --";
time rm -rf -- "$REV_SOURCE";
echo "there is no rm -rf undo; nothing restores this";

echo;
echo "==================================================";
echo "5. Detectability: canary formula (not a field measurement)";
echo "why this matters: a small canary can miss a real fault more often than it feels like it should";
echo "==================================================";
python3 -c "
print(f\"{'fault_rate':<12}{'canary=1':<10}{'canary=3':<10}{'canary=5':<10}{'canary=10'}\")
for rate in [0.01, 0.05, 0.10, 0.25, 0.50]:
    row = [f'{100*(1-(1-rate)**c):.1f}%' for c in [1,3,5,10]]
    print(f'{rate*100:>8.0f}%   ' + '   '.join(f'{v:<7}' for v in row))
";

echo;
echo "==================================================";
echo "6. Direction: stratified vs. random sampling in a 200-machine fleet, fault confined to a 20-machine config";
echo "why this matters: how you choose a sample can matter more than how big the sample is";
echo "==================================================";
python3 - << 'PY'
import random
random.seed(20260919)  # reproducible on a given Python version; random.sample's
                        # own algorithm is not guaranteed stable across versions
                        # the way random() itself is, per CPython's own docs
N, TRIALS = 200, 200_000
# Named explicitly so the label in the printed output can never drift from
# what the code actually does, unlike an earlier version of this script.
configs = {"A": list(range(0, 60)), "B": list(range(60, 120)), "C": list(range(120, 180)), "D": list(range(180, 200))}
faulty_set = set(configs["D"])
machines = list(range(N))

def random_detects(n):
    return any(m in faulty_set for m in random.sample(machines, n))
def stratified_detects():
    return any(any(m in faulty_set for m in random.sample(c, 1)) for c in configs.values())

print(f"fleet of {N}, fault confined to config D ({len(faulty_set)} targets, {100*len(faulty_set)//N}% of fleet)")
for n in [1, 4, 5, 10, 20]:
    hits = sum(random_detects(n) for _ in range(TRIALS))
    print(f"  random sample of {n:<3} -> detection {100*hits/TRIALS:5.1f}%")
hits = sum(stratified_detects() for _ in range(TRIALS))
assert hits == TRIALS, "config D is always in a 1-per-config stratified draw; a miss means the construction is broken, not just unlucky"
print(f"  stratified 1 per config (4 targets) -> detection {100*hits/TRIALS:5.1f}%")
PY

echo;
echo "==================================================";
echo "7. Structural limits: root vs. uid 65534, walk and delete";
echo "why this matters: a boundary enforced by the kernel doesn't depend on the job's code being correct";
echo "==================================================";
if [ "$(id -u)" -ne 0 ] || [ "$SETPRIV_AVAILABLE" -ne 1 ]; then
  echo "This section demonstrates a kernel-enforced permission boundary and";
  echo "needs chown/setpriv, which need root and setpriv installed. Skipping;";
  echo "sections 1-6 above need neither and already ran.";
  SECTION_7_STATUS="SKIPPED (requires root + setpriv)";
else
  PERM_DEMO="$(mktemp -d /tmp/revisualized_blast_radius_permission_boundary.XXXXXX)";
  register_sandbox "$PERM_DEMO";
  chmod 755 "$PERM_DEMO";
  mkdir -p "$PERM_DEMO/owned" "$PERM_DEMO/protected";
  touch "$PERM_DEMO/owned/scratch.txt" "$PERM_DEMO/protected/critical.conf";
  chown -R 65534:65534 "$PERM_DEMO/owned";
  chmod 700 "$PERM_DEMO/protected";
  echo "-- as root, ordinary DAC permissions do not stop the job --";
  find "$PERM_DEMO" -type f;
  echo "-- as uid 65534, the kernel refuses the out-of-scope half --";
  ( cd /tmp && setpriv --reuid 65534 --regid 65534 --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs find "$PERM_DEMO" -type f ) || true;
  echo "-- attempting deletion under the restricted identity against both halves --";
  ( cd /tmp && setpriv --reuid 65534 --regid 65534 --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs rm -f "$PERM_DEMO/owned/scratch.txt" ) || true;
  ( cd /tmp && setpriv --reuid 65534 --regid 65534 --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs rm -f "$PERM_DEMO/protected/critical.conf" ) || true;
  OWNED_PRESENT="$( [ -f "$PERM_DEMO/owned/scratch.txt" ] && echo yes || echo no )";
  PROTECTED_PRESENT="$( [ -f "$PERM_DEMO/protected/critical.conf" ] && echo yes || echo no )";
  echo "owned file still present: $OWNED_PRESENT";
  echo "protected file still present: $PROTECTED_PRESENT";
  if [ "$OWNED_PRESENT" = no ] && [ "$PROTECTED_PRESENT" = yes ]; then
    SECTION_7_STATUS="PASS";
  else
    SECTION_7_STATUS="FAIL (boundary did not behave as demonstrated)";
  fi;
fi;

echo;
echo "==================================================";
echo "RESULT";
echo "==================================================";
echo "sections 1-6: PASS";
echo "section 7:    $SECTION_7_STATUS";
if [ "$SECTION_7_STATUS" = "PASS" ] || [ "$SECTION_7_STATUS" = "SKIPPED (requires root + setpriv)" ]; then
  echo "DEMONSTRATIONS: PASS (the script ran cleanly and its checks passed; this confirms the demonstrations execute as described, not that the operational model has been validated against production)";
else
  echo "DEMONSTRATIONS: FAIL";
  exit 1;
fi;
