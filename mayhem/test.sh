#!/usr/bin/env bash
#
# mayhem/test.sh — the BEHAVIORAL oracle for boytacean's Game Boy cartridge loader.
#
# It RUNS the KAT probe (/mayhem/rom_kat, built by mayhem/build.sh): a dynamically
# linked binary that hand-encodes a canonical 32 KiB Game Boy ROM, parses it with the
# UNMODIFIED boytacean::rom::Cartridge, and prints a `KAT_RESULT ...` line. We then
# assert EXACT decoded values (title, cartridge/MBC type, ROM size, RAM size, CGB
# flag, ROM-bank count) with bash/coreutils — so a neutered/broken loader (the gate's
# LD_PRELOAD sabotage shim _exit(0)s the probe) prints nothing and this FAILS.
# Known-answer, not exit-code: a no-op PATCH of the loader cannot pass this (§6.3).
#
# Emits a CTRF summary; exit 0 iff failed==0. Does NOT compile (build.sh did).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

KAT=/mayhem/rom_kat
if [ ! -x "$KAT" ]; then
  echo "ERROR: KAT probe $KAT missing — build.sh must produce it" >&2
  emit_ctrf "boytacean-rom-kat" 0 1 0
  exit 1
fi

# Run the probe and capture its output (do NOT let a probe crash kill the script).
OUT="$("$KAT" 2>&1)" || true
echo "$OUT"

LINE="$(printf '%s\n' "$OUT" | grep -m1 '^KAT_RESULT ' || true)"

# Each decoded field is one known-answer assertion.
EXPECT=(
  "title=TESTROM"
  "rom_type=RomOnly"
  "rom_size=Size32K"
  "ram_size=NoRam"
  "cgb=NoCgb"
  "mbc=NoMbc"
  "rom_banks=2"
)

PASSED=0
FAILED=0
if [ -z "$LINE" ]; then
  echo "FAIL: no KAT_RESULT line from the cartridge loader probe" >&2
  FAILED=${#EXPECT[@]}
else
  for tok in "${EXPECT[@]}"; do
    if printf '%s' "$LINE" | grep -qwF -- "$tok"; then
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: expected '$tok' in KAT_RESULT" >&2
      FAILED=$((FAILED + 1))
    fi
  done
fi

emit_ctrf "boytacean-rom-kat" "$PASSED" "$FAILED" 0
