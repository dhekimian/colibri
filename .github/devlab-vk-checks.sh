#!/usr/bin/env bash
# The pieces of `tests/vulkan_engines.sh shader` and `staged`, one check each, on the device
# VK_ICD_FILENAMES names. The upstream script stops at its first failure (and under set -e
# hides the output of the staged ones), so one known failure would hide every later case.
# Here each piece runs and lands in $RESULTS as <check>=pass|fail. A test that fails with
# "FAIL file:line: <case>, ..." lines also records <check>:<case>=fail per distinct case,
# so .github/devlab-known-failures.txt can name a case instead of a whole program.
set -uo pipefail
cd "$(dirname "$0")/../c"
RESULTS=${RESULTS:-/src/results.txt}
LOGS=${LOGS:-/src/vk-logs}
mkdir -p "$LOGS"
result() { echo "$1=$2" >> "$RESULTS"; }

# run <check> <log> <cmd...>: pass when the command exits 0 and its last line says PASS
run() {
  local name=$1 log=$LOGS/$2.log; shift 2
  "$@" > "$log" 2> "${log%.log}.err"; local rc=$?
  if [ $rc = 0 ] && tail -1 "$log" | grep -q '^PASS'; then result "$name" pass; return 0; fi
  result "$name" fail
  echo "---- $name failed (exit $rc), the failing lines:"
  grep -aE '^FAIL |  \^|DIFFERENT' "$log" | head -20 || true
  # the harness names no failing case: its import cases fail over maxrel 1e-3 (run_import_case)
  awk -F' [|] ' '/^import fmt=/ { split($2, a, "="); if (a[2] + 0 > 1e-3) { print; n = $1; gsub(/[^A-Za-z0-9.=-]+/, "-", n); print n > "/dev/stderr" } }' "$log" 2> "$log.cases"
  while read -r c; do result "$name:$c" fail; done < "$log.cases"
  grep -aoE '^FAIL [^:]+:[0-9]+: [^,:]+' "$log" | sed -E 's/^FAIL [^:]+:[0-9]+: //; s/[^A-Za-z0-9._-]+/-/g' | sort -u |
    while read -r c; do result "$name:$c" fail; done
  return 1
}

make tests/test_vk_tier tests/test_vk_chain tests/test_glm53_vk_f32 VK=1 > "$LOGS/build.log" 2>&1 || { cat "$LOGS/build.log"; result vk-build fail; exit 1; }
cc -O2 -pthread -DVK_TEST backend_vulkan.c -o vk_test -ldl -lm || { result vk-build fail; exit 1; }
result vk-build pass

# shader: the harness on the default path and on the fp32 GEMM only (no cooperative matrix)
run vk-harness harness env COLI_VK_TEST_MATMUL_ONLY=1 ./vk_test shaders/qmatmul.spv
grep -a '^\[VK\] ready' "$LOGS/harness.err" || true
run vk-harness-nocoop harness-nocoop env COLI_VK_COOP=0 COLI_VK_TEST_MATMUL_ONLY=1 ./vk_test shaders/qmatmul.spv
run vk-tier tier ./tests/test_vk_tier shaders/qmatmul.spv
run vk-tier-host-pairs tier-hp ./tests/test_vk_tier shaders/qmatmul.spv host-pairs
run glm53-f32 glm53 ./tests/test_glm53_vk_f32
run glm53-f32-gemm-min-s0 glm53-s0 env COLI_VK_GEMM_MIN_S=0 ./tests/test_glm53_vk_f32

# staged: the harness's results bit for bit the same mapped, staged and under a 246 MB window
# (COLI_VK_COOP=0: the default path's import case is a known failure, vk-harness above)
d0=""
for m in mapped staged staged-again staged-noimport window; do
  case $m in
    mapped) e=COLI_VK_STAGED=0 ;;
    staged|staged-again) e=COLI_VK_STAGED=1 ;;
    staged-noimport) e="COLI_VK_STAGED=1 COLI_VK_UP_IMPORT=0" ;;
    window) e=COLI_VK_HOST_VISIBLE_CAP_MB=246 ;;
  esac
  log=$LOGS/staged-$m.log
  if run "staged-harness-$m" "staged-$m" env $e COLI_VK_COOP=0 COLI_VK_TEST_MATMUL_ONLY=1 ./vk_test shaders/qmatmul.spv; then
    if [ $m = mapped ]; then grep -qx 'memory: mapped' "$log" || result "staged-harness-$m:not-mapped" fail
    else grep -q '^\[VK\] memory: staged uploads' "${log%.log}.err" || result "staged-harness-$m:not-staged" fail; fi
    d=$(sed -n 's/^outputs digest //p' "$log")
    [ -n "$d0" ] || d0=$d
    [ "$d" = "$d0" ] || result "staged-harness-$m:digest-differs" fail
    echo "staged harness $m: digest $d"
  fi
done
run staged-tier staged-tier env COLI_VK_STAGED=1 ./tests/test_vk_tier shaders/qmatmul.spv
run staged-tier-noimport staged-tier-noimport env COLI_VK_STAGED=1 COLI_VK_UP_IMPORT=0 ./tests/test_vk_tier shaders/qmatmul.spv
run staged-chain staged-chain env COLI_VK_STAGED=1 ./tests/test_vk_chain shaders/qmatmul.spv
for t in staged-tier staged-chain; do
  grep -q 'resident data in host memory: 0.0 MiB' "$LOGS/$t.err" || result "$t:resident-in-host-memory" fail
done
exit 0
