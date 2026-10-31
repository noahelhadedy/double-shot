#!/bin/sh
# Scenario suite for Cursor agent detection.
#
# Note: when this script is launched as a Cursor agent tool, its own shell is a
# child of agent-exec — so a live "idle" observation is impossible mid-script.
# Idle-after-stop is covered by unit tests (idle shell, turn_ended) and by a
# delayed detached probe scheduled at the end (reads /tmp/ds-idle-verify.txt).
#
# Usage: scripts/test-cursor-scenarios.sh
set -e
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }

probe() {
    swift run DoubleShot --probe-agents "$@" 2>/dev/null | grep 'isAnyWorking=' | tail -1
}

tool_child_count() {
    python3 - <<'PY'
import subprocess
rows=[]
for line in subprocess.check_output(['ps','-axo','pid=,ppid=,comm=,args='], text=True).splitlines():
    p=line.strip().split(None,3)
    if len(p)<4: continue
    rows.append((int(p[0]), int(p[1]), p[2], p[3]))
ch={}
for r in rows: ch.setdefault(r[1], []).append(r)
n=0
for a in rows:
    if 'agent-exec' not in a[3]: continue
    for c in ch.get(a[0], []):
        for g in ch.get(c[0], []):
            n += 1
print(n)
PY
}

echo "== 1) Unit tests =="
if swift test --filter AgentActivityRulesTests 2>&1 | tee /tmp/ds-unit.txt | grep -q "0 failures"; then
    pass "AgentActivityRulesTests (idle shell, tool child, turn_ended, latch off/on, …)"
else
    fail "unit tests"
    tail -30 /tmp/ds-unit.txt
fi

echo ""
echo "== 2) Latch flag =="
OUT=$(probe --latch=0)
echo "      $OUT"
case "$OUT" in *latch=off*) pass "latch=0 => latch=off" ;; *) fail "no latch=off: $OUT" ;; esac
OUT=$(probe)
echo "      $OUT"
case "$OUT" in *latch=off*) fail "default should not print latch=off" ;; *isAnyWorking=*) pass "default latch (production 2.5m)" ;; *) fail "bad default: $OUT" ;; esac

echo ""
echo "== 3) Busy Cursor tool => working (latch off) =="
( sleep 5 ) &
SP=$!
sleep 1
OUT=$(probe --latch=0)
KIDS=$(tool_child_count)
echo "      kids=$KIDS $OUT"
wait $SP 2>/dev/null || true
case "$OUT" in
    *isAnyWorking=true*) pass "active tool => working" ;;
    *) fail "expected working during tool: $OUT" ;;
esac
if [ "$KIDS" -gt 0 ]; then pass "process tree shows tool children"; else fail "expected tool children during sleep"; fi

echo ""
echo "== 4) Schedule delayed idle verify (detached, 20s after this script) =="
VERIFY=/tmp/ds-idle-verify.txt
rm -f "$VERIFY"
REPO="$(pwd)"
python3 - "$REPO" "$VERIFY" <<'PY' &
import os, sys, time, subprocess
repo, verify = sys.argv[1], sys.argv[2]
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        time.sleep(20)
        # wait until agent-exec has no tool grandchildren, up to 40s more
        def kids():
            import subprocess as sp
            rows=[]
            for line in sp.check_output(['ps','-axo','pid=,ppid=,args='], text=True).splitlines():
                p=line.strip().split(None,2)
                if len(p)<3: continue
                rows.append((int(p[0]), int(p[1]), p[2]))
            ch={}
            for r in rows: ch.setdefault(r[1], []).append(r)
            n=0
            for a in rows:
                if 'agent-exec' not in a[2]: continue
                for c in ch.get(a[0], []):
                    n += len(ch.get(c[0], []))
            return n
        for _ in range(40):
            if kids() == 0:
                break
            time.sleep(1)
        cmd=["swift","run","DoubleShot","--probe-agents","--latch=0"]
        p=subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
        line=next((l for l in p.stdout.splitlines() if 'isAnyWorking=' in l), p.stdout.strip())
        with open(verify,'w') as f:
            f.write(f"kids={kids()}\n{line}\n")
        os._exit(0)
    os._exit(0)
os.wait()
PY
pass "scheduled /tmp/ds-idle-verify.txt (wait ~20–60s after agent tools stop)"

echo ""
echo "== 5) Watch observes working while tools run =="
LOG=/tmp/ds-watch-scenario.log
rm -f "$LOG"
swift run DoubleShot --probe-agents --watch --interval=1 --latch=0 >"$LOG" 2>/dev/null &
WP=$!
( sleep 3 ) &
wait $! 2>/dev/null || true
sleep 1
kill $WP 2>/dev/null || true
wait $WP 2>/dev/null || true
grep -E 'status|changed|Watching' "$LOG" || true
if grep -q 'isAnyWorking=true' "$LOG"; then pass "watch saw working"; else fail "watch missed working"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Delayed idle check will land in /tmp/ds-idle-verify.txt once Cursor tool shells are gone."
[ "$FAIL" -eq 0 ]
