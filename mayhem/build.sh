#!/usr/bin/env bash
#
# mayhem/build.sh — build boytacean's Game Boy ROM-loader / emulator fuzz targets as
# sanitized libFuzzer binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS),
# and the KAT oracle probe (clean, non-sanitized) that mayhem/test.sh RUNS.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem. The
# Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) populates the cargo registry under $CARGO_HOME AND
#     writes the standalone lockfiles (mayhem/fuzz/Cargo.lock, mayhem/kat/Cargo.lock),
#     so the offline re-run finds the lock already resolved and SKIPS the network
#     resolve. We do NOT hard-code `--offline`.
#
# boytacean is a multi-crate cargo workspace. We do NOT reuse it; instead we ship two
# ADDITIVE, standalone (own [workspace]) crates under mayhem/ that depend on the
# UNMODIFIED boytacean crate via a path dependency (with only the `gen-mock` feature,
# which makes the upstream build.rs a no-op — see the crate manifests):
#   - mayhem/fuzz -> targets `fuzz-cartridge`, `fuzz-run` (the sanitized libFuzzer bins)
#   - mayhem/kat  -> binary  `rom_kat` (the behavioral-oracle KAT probe)
# Upstream files are untouched.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_DIR="mayhem/fuzz"
KAT_DIR="mayhem/kat"

# ── dependency pins for the pinned nightly (build artifacts only; NEVER touch upstream) ──
# Only fire when the resolver actually pulled a breaking version (never attempt an
# impossible cross-major --precise, which would abort set -e).
lock_ver() {  # <lockfile> <crate> -> resolved version (empty if absent)
  awk -v c="$2" '
    $1=="name" && $3=="\""c"\"" {found=1; next}
    found && $1=="version" {gsub(/"/,"",$3); print $3; exit}
  ' "$1" 2>/dev/null
}
apply_pins() {  # <manifest> <lockfile>
  local manifest="$1" lock="$2" v
  # zerocopy 0.8.27+ uses the still-unstable stdarch_x86_avx512 feature on this nightly.
  v="$(lock_ver "$lock" zerocopy)"
  case "$v" in
    0.8.2[7-9]|0.8.[3-9]*|0.9.*|0.[1-9][0-9].*)
      echo "  pin zerocopy $v -> 0.8.26"
      env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo update --manifest-path "$manifest" -p zerocopy --precise 0.8.26 ;;
  esac
  # half 2.5+ pulls a zerocopy with the same problem.
  v="$(lock_ver "$lock" half)"
  case "$v" in
    2.5.*|2.[6-9].*|2.[1-9][0-9].*|[3-9].*)
      echo "  pin half $v -> 2.4.1"
      env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo update --manifest-path "$manifest" -p half --precise 2.4.1 ;;
  esac
}
resolve_lock() {  # <crate-dir>
  local dir="$1"
  local manifest="$dir/Cargo.toml"
  local lock="$dir/Cargo.lock"
  if [ -f "$lock" ]; then
    echo "=== $lock exists — reusing (offline-safe) ==="
  else
    echo "=== generating $lock ==="
    env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo generate-lockfile --manifest-path "$manifest"
    apply_pins "$manifest" "$lock"
  fi
}

resolve_lock "$FUZZ_DIR"
resolve_lock "$KAT_DIR"

# ── sanitizers (§6.1) ──────────────────────────────────────────────────────────
# The base provides clang $SANITIZER_FLAGS (ASan+UBSan, halting). rustc can't consume
# those clang flags, but we honor the KNOB: when $SANITIZER_FLAGS is non-empty we
# instrument the Rust fuzz build with ASan; an explicit empty --build-arg
# SANITIZER_FLAGS= yields an un-sanitized build.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi

# ── debug info (§6.2 item 10): DWARF < 4 (Mayhem triage can't read DWARF >= 4) ──
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The bundled ASan runtime archive that -Zsanitizer=address links is clang-compiled
# (DWARF-5) with full debug info, which would otherwise land a DWARF-5 compile unit as
# the binary's FIRST CU and fail the DWARF < 4 gate. Strip debug info from that runtime
# archive (a toolchain artifact, NOT project code). Idempotent (offline-safe).
if [ -n "${RUST_SAN}" ]; then
  RT_LIB_DIR="$(rustc --print sysroot)/lib/rustlib/${TRIPLE}/lib"
  for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
    [ -f "$asan" ] || continue
    if [ -w "$asan" ]; then
      objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
      echo "stripped debug info from bundled ASan runtime: $asan"
    fi
  done
fi

# ── discover + build every fuzz target ─────────────────────────────────────────
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # mayhem/fuzz is its OWN workspace, so cargo-fuzz writes under $FUZZ_DIR/target/.
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── build the KAT oracle probe (clean, non-sanitized: NORMAL flags) ─────────────
echo "=== building KAT oracle probe (cargo build --release, clean flags) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo build --release --manifest-path "$KAT_DIR/Cargo.toml"
KAT_BIN="$SRC/$KAT_DIR/target/release/rom_kat"
[ -x "$KAT_BIN" ] || { echo "ERROR: KAT probe not built at $KAT_BIN" >&2; exit 1; }
cp "$KAT_BIN" /mayhem/rom_kat
echo "built /mayhem/rom_kat"

# Regression guard (§4): the oracle probe MUST be dynamically linked so the gate's
# LD_PRELOAD sabotage shim can neuter it.
if ! file /mayhem/rom_kat | grep -q 'dynamically linked'; then
  echo "ERROR: /mayhem/rom_kat is NOT dynamically linked — oracle would be immune to sabotage" >&2
  file /mayhem/rom_kat >&2
  exit 1
fi
echo "KAT probe is dynamically linked (oracle sabotage-detectable)"

echo "build.sh complete"
