#!/usr/bin/env bash
#
# ckb/mayhem/build.sh — build nervosnetwork/ckb's in-tree cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (`cargo fuzz build -O` + ASan via RUSTFLAGS).
#
# ckb is the Nervos CKB blockchain node. Its UPSTREAM fuzz crate lives at script/fuzz/ (crate
# `ckb-script-fuzz`, libfuzzer-sys 0.4 + arbitrary 1, path deps on ckb-script / ckb-types /
# ckb-traits / ckb-chain-spec). That upstream crate does NOT compile under the rustc the node now
# requires: ckb-types 1.1.2 / ckb-traits 1.1.1 need rustc >= 1.95.0 (→ newer nightly), and under that
# rustc every upstream target fails with `error[E0283]: type annotations needed` on
# `.hash_type(ScriptHashType::DataN.into())` — upstream commit e410c25d1 added a second `Into<Byte>`
# impl, so the redundant `.into()` no longer infers. This is inherent to the upstream code regardless
# of which >=1.95.0 toolchain is chosen. To stay PURELY ADDITIVE (we never edit any upstream file) we
# build an ADDITIVE copy of the same five targets under mayhem/fuzz/, applying only the trivial fix
# the compiler itself suggests (drop the redundant `.into()`). The FUZZED code is identical: the
# targets still drive the real ckb-script verifier through path deps on the upstream node crates, and
# their include_bytes! blobs point back at the real upstream script/fuzz/programs + script/testdata.
# mayhem/fuzz declares its own `[workspace]` so it is independent of the node workspace's
# rust-toolchain.toml pin (1.95.0); the Dockerfile's RUSTUP_TOOLCHAIN=nightly-... overrides any
# toolchain file anyway (cargo-fuzz needs nightly for -Z flags).
#
# The crate ships five targets, all driving the REAL ckb-script transaction-script verifier
# (ckb_script::TransactionScriptsVerifier::verify, which runs the CKB-VM RISC-V interpreter over
# lock/type scripts):
#   transaction_scripts_verifier_data0  — old fork target `data0`
#   transaction_scripts_verifier_data1  — old fork target `data1`
#   transaction_scripts_verifier_data2
#   syscall_exec                         — old fork target `syscall-exec`
#   syscall_spawn
# The old fork shipped data0/data1/syscall_exec; we expose ALL five (each at /mayhem/<target>) so the
# set stays in lock-step with upstream.
#
# cargo-fuzz drives the build: it provides its own libFuzzer runtime (the produced binary IS a
# libFuzzer target — Mayhem runs it directly via `libfuzzer: true`), and ASan is enabled the Rust way
# through RUSTFLAGS `-Zsanitizer=address` (NOT clang's $SANITIZER_FLAGS / CFLAGS — those don't apply
# to rustc), which is what OSS-Fuzz's `compile` sets for FUZZING_LANGUAGE=rust. nightly is required
# for `-Zsanitizer`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# The additive mayhem/fuzz cargo-fuzz crate (copies of the upstream targets, see header). Discover
# every target from its fuzz_targets/ dir so the set stays in lock-step with the upstream set.
FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
# Debug-info contract (SPEC section 6.2 item 10): thread $RUST_DEBUG_FLAGS so the fuzz binaries carry
# a .debug_info section with DWARF < 4 (Mayhem triage cannot read DWARF >= 4). The default forces
# DWARF-3 via rustc (-Zdwarf-version=3, nightly); the base image may override RUST_DEBUG_FLAGS.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS"
# libfuzzer-sys compiles a bundled libFuzzer via the cc crate (clang -> DWARF-5 by default); force
# DWARF-3 on those C/C++ objects too, so NO compilation unit in the linked binary is >= 4 (the
# prebuilt std/asan archives are debug-stripped in the Dockerfile).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "fuzz dir: $FUZZ_DIR"
echo "targets: ${FUZZ_TARGETS[*]}"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's Rust build. Use the image's DEFAULT
# toolchain (the Dockerfile pins it to the required nightly via RUSTUP_TOOLCHAIN); a `+toolchain`
# override would make rustup try to install a different channel into the read-only shared
# /opt/toolchains/rust. Build per-target so a single bad target doesn't mask the others.
# Force a clean relink so no stale DWARF-5 object lingers from a prior cache (memory: old-rust-dwarf).
rm -rf "$SRC/$FUZZ_DIR/target"
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "/mayhem/${FUZZ_TARGETS[@]}" 2>&1 || true
