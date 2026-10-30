#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS the pre-built clean (unsanitized) oracle binaries from mayhem/build.sh:
# libjpeg-turbo cjpeg/djpeg/jpegtran known-answer md5s, libpng pngtest round-trip hash, and the
# utf8proc test programs (whose printed success lines are asserted, not just their exit codes).
# Writes a CTRF report and prints a `CTRF {...}` marker; exit 0 iff nothing failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

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

OUT="$SRC/mayhem/out"
LIBS="$SRC/BSD/lib"
IMG="$LIBS/libjpeg/testimages"
CJPEG="$OUT/jpeg-test/cjpeg-static"
DJPEG="$OUT/jpeg-test/djpeg-static"
JPEGTRAN="$OUT/jpeg-test/jpegtran-static"
PNGTEST="$OUT/png-test/pngtest"

for f in "$CJPEG" "$DJPEG" "$JPEGTRAN" "$PNGTEST" "$OUT"/utf8proc-test-{case,custom,iterate,misc,valid}; do
  [ -x "$f" ] || { echo "missing $f — mayhem/build.sh did not build it" >&2; emit_ctrf ravynos-oracle 0 1; exit 1; }
done

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
passed=0; failed=0

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); echo "ok   $1"
  else failed=$((failed + 1)); echo "FAIL $1: expected '$2' got '$3'"; fi
}
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# libjpeg-turbo: known-answer md5 of each tool's output
"$CJPEG" -quality 75 -outfile "$W/a.jpg" "$IMG/testorig.ppm" >/dev/null 2>&1
check "cjpeg -quality 75 testorig.ppm" 9a68f56bc76e466aa7e52f415d0f4a5f "$(md5 "$W/a.jpg")"
"$CJPEG" -dct int -quality 90 -outfile "$W/b.jpg" "$IMG/testorig.ppm" >/dev/null 2>&1
check "cjpeg -dct int -quality 90 testorig.ppm" 5a64e0ae3f94916818ce564a1509a745 "$(md5 "$W/b.jpg")"
"$DJPEG" -dct int -ppm -outfile "$W/c.ppm" "$IMG/testorig.jpg" >/dev/null 2>&1
check "djpeg -dct int testorig.jpg" dea1d7bbc37e39adf628342c86096641 "$(md5 "$W/c.ppm")"
"$DJPEG" -dct int -ppm -outfile "$W/f.ppm" "$W/a.jpg" >/dev/null 2>&1
check "djpeg of cjpeg output" 4aaa551ce59d429ac673f730a56cd73d "$(md5 "$W/f.ppm")"
"$JPEGTRAN" -rotate 90 -outfile "$W/d.jpg" "$IMG/testorig.jpg" >/dev/null 2>&1
check "jpegtran -rotate 90 testorig.jpg" d495dabdc23f67da93aa6ffcaa82d109 "$(md5 "$W/d.jpg")"
"$JPEGTRAN" -copy none -outfile "$W/e.jpg" "$IMG/testorig.jpg" >/dev/null 2>&1
check "jpegtran lossless copy is byte-identical" 3016112edb6ff1a7af3c2c0093df75a4 "$(md5 "$W/e.jpg")"

# libpng: pngtest reads and rewrites pngtest.png, and must say it passes
png_log="$("$PNGTEST" "$LIBS/libpng/pngtest.png" "$W/o.png" 2>&1)"
case "$png_log" in *"libpng passes test"*) png_ok=pass ;; *) png_ok=nopass ;; esac
check "pngtest verdict" pass "$png_ok"
check "pngtest round-trip sha256" 546f711f1f5b493ad7a79a5ec0c37f30e35f59be97b92731a9ddb01a225df5d8 \
  "$(sha256sum "$W/o.png" 2>/dev/null | cut -d' ' -f1)"

# utf8proc: each program prints its own success line; iterate also reports its assertion count
cd "$LIBS/libutf8"
u_out() { "$OUT/utf8proc-test-$1" 2>&1; }
check "utf8proc case"    "utf8proc case conversion tests SUCCEEDED." "$(u_out case    | grep 'tests SUCCEEDED' | tail -1)"
check "utf8proc custom"  "map_custom tests SUCCEEDED."               "$(u_out custom  | grep 'tests SUCCEEDED' | tail -1)"
check "utf8proc iterate" "utf8proc_iterate tests SUCCEEDED, (673) tests passed." "$(u_out iterate | grep 'tests SUCCEEDED' | tail -1)"
check "utf8proc misc"    "Misc tests SUCCEEDED."                     "$(u_out misc    | grep 'tests SUCCEEDED' | tail -1)"
check "utf8proc valid"   "Validity tests SUCCEEDED."                 "$(u_out valid   | grep 'tests SUCCEEDED' | tail -1)"

emit_ctrf ravynos-oracle "$passed" "$failed"
