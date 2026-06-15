#!/usr/bin/env bash
#
# ckb/mayhem/test.sh — RUN ckb-script's own functional test suite (the crate the fuzz targets drive)
# and emit a CTRF summary. exit 0 iff no test failed. This script only RUNS the suite (via
# `cargo test`); it never builds the fuzz targets.
#
# PATCH-grade oracle. All five fuzz targets call ckb_script::TransactionScriptsVerifier::verify — the
# CKB transaction-script verifier that drives the CKB-VM RISC-V interpreter over lock/type scripts
# and the exec/spawn syscalls. The ckb-script crate ships an extensive in-tree suite
# (script/src/verify/tests/* and script/src/syscalls/tests/*) that asserts EXACT verification
# outcomes (Ok/Err with specific error kinds, cycle counts, syscall behavior) against compiled
# RISC-V test programs in script/testdata/. A no-op / "return Ok(())" / output-altering patch to the
# verifier fails these asserts. We scope strictly to `-p ckb-script` (NOT the whole node) to keep the
# oracle fast and focused on the fuzzed code.
#
# We run with NORMAL flags (no sanitizer RUSTFLAGS) on the image's DEFAULT toolchain — a separate,
# clean build from build.sh's. (script/fuzz is its own workspace; we test the node-workspace
# ckb-script crate, which is what the path-dep `ckb-script = { path = "../../script" }` resolves to.)
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# The ckb-script verify suite spins up many on-disk RocksDB instances concurrently; with the
# container's default soft fd limit (1024) and a high core count, parallel test threads exhaust file
# descriptors and the suite fails with "Too many open files" (a RESOURCE artifact, not a real test
# failure). Raise the soft fd limit to the hard cap and bound the number of concurrent test threads
# so the suite runs deterministically. This affects ONLY the oracle run, never the fuzzed code.
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
# Cap runtime test threads (each RocksDB-heavy test opens dozens of fds); 4 keeps fd use well under
# the limit while staying reasonably fast. cargo --jobs controls build parallelism (left at full).
: "${TEST_THREADS:=4}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test -p ckb-script (transaction-script verifier + syscall unit suites) ==="
# --no-fail-fast so we count every test; RUSTFLAGS cleared so it inherits nothing from the sanitizer
# build. Use the image's DEFAULT toolchain (no +toolchain override).
out="$(RUSTFLAGS="" cargo test -p ckb-script --no-fail-fast --jobs "$MAYHEM_JOBS" -- --test-threads="$TEST_THREADS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries.
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
