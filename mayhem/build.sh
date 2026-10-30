#!/usr/bin/env bash
#
# mayhem/build.sh — builds the fuzz harnesses for the vendored libraries under BSD/lib
# (libjpeg-turbo, libpng, utf8proc) plus the clean oracle build that mayhem/test.sh runs.
#
# Build directories live in mayhem/out/ (gitignored); fuzz binaries land in /mayhem/<name>,
# reproducers in /mayhem/<name>-standalone. Safe to re-run offline (cmake reconfigures in place,
# nothing is fetched).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

LIBS="$SRC/BSD/lib"
JPEG="$LIBS/libjpeg"
PNG="$LIBS/libpng"
UTF8="$LIBS/libutf8"
OUT="$SRC/mayhem/out"
mkdir -p "$OUT"

# Instrumentation for the fuzz build: sanitizers + DWARF<=3 + SanCov in the library code itself
# (the engine only covers the harness TU). The standalone reproducer build gets no SanCov, so it
# links without the libFuzzer runtime.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
SA_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# Shared objects: LLVM's run-once driver (as C, so C++ harnesses keep C linkage for
# LLVMFuzzerTestOneInput) and the LeakSanitizer off-switch.
$CC $SA_CFLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"
$CXX $SA_CFLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/lsan_off.o"

# link_pair <name> <fuzz-flags> <standalone-flags> <sources...> -- <libs for fuzz> -- <libs for standalone>
# Each harness is linked twice: libFuzzer binary + standalone reproducer.
cmake_lib() { # <srcdir> <builddir> <cflags> <extra cmake args...>
  local src="$1" bld="$2" flags="$3"; shift 3
  cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
    -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG" \
    -DCMAKE_EXE_LINKER_FLAGS="$flags" "$@" >/dev/null
}

# ---------------------------------------------------------------- libjpeg-turbo
JPEG_ARGS=(-DENABLE_STATIC=1 -DENABLE_SHARED=0 -DWITH_SIMD=0 -DWITH_JAVA=0 -DWITH_TURBOJPEG=1)
cmake_lib "$JPEG" "$OUT/jpeg-fuzz" "$FUZZ_CFLAGS" "${JPEG_ARGS[@]}"
cmake_lib "$JPEG" "$OUT/jpeg-sa"   "$SA_CFLAGS"   "${JPEG_ARGS[@]}"
cmake --build "$OUT/jpeg-fuzz" -j"$MAYHEM_JOBS" --target turbojpeg-static jpeg-static
cmake --build "$OUT/jpeg-sa"   -j"$MAYHEM_JOBS" --target turbojpeg-static jpeg-static

# The cjpeg harness also compiles the cjpeg front-end readers. Upstream's CMake passes
# CDJPEG_COMPILE_FLAGS (the *_SUPPORTED switches) to these files and to the harness; without them
# cjpeg.c compiles with no BMP/GIF/PPM/Targa reader and rejects every input. cjpeg.c also needs the
# 12- and 16-bit rdgif/rdppm objects (cjpeg12-static/cjpeg16-static upstream).
CJPEG_DEFS="-DBMP_SUPPORTED -DGIF_SUPPORTED -DPPM_SUPPORTED -DTARGA_SUPPORTED"
CJPEG_C=("$JPEG/cdjpeg.c" "$JPEG/rdbmp.c" "$JPEG/rdgif.c" "$JPEG/rdppm.c" "$JPEG/rdswitch.c" "$JPEG/rdtarga.c")

build_jpeg() { # <name> <harness.cc> <mode: tj|cjpeg>
  local name="$1" harness="$2" mode="$3" mode_srcs
  for variant in fuzz sa; do
    local flags engine libs out defs=""
    [ "$mode" = cjpeg ] && defs="$CJPEG_DEFS"
    if [ "$variant" = fuzz ]; then
      flags="$FUZZ_CFLAGS"; engine="$LIB_FUZZING_ENGINE"; out="$SRC/$name"
    else
      flags="$SA_CFLAGS"; engine="$OUT/standalone_main.o"; out="$SRC/$name-standalone"
    fi
    local bld="$OUT/jpeg-$variant"
    if [ "$mode" = cjpeg ]; then
      libs=("$bld/libjpeg.a")
      mode_srcs=()
      for f in "${CJPEG_C[@]}"; do
        local o="$bld/$(basename "$f" .c)-$name.o"
        $CC $flags $CJPEG_DEFS -I"$JPEG" -I"$bld" -c "$f" -o "$o"
        mode_srcs+=("$o")
      done
      for bits in 12 16; do
        for f in rdgif rdppm; do
          local o="$bld/$f$bits-$name.o"
          $CC $flags -DBITS_IN_JSAMPLE=$bits -DGIF_SUPPORTED -DPPM_SUPPORTED \
            -I"$JPEG" -I"$bld" -c "$JPEG/$f.c" -o "$o"
          mode_srcs+=("$o")
        done
      done
    else
      libs=("$bld/libturbojpeg.a")
      mode_srcs=()
    fi
    $CXX $flags ${defs:-} -I"$JPEG" -I"$bld" "$harness" ${mode_srcs[@]+"${mode_srcs[@]}"} \
      $engine "$OUT/lsan_off.o" "${libs[@]}" -o "$out"
  done
}

build_jpeg cjpeg_fuzzer               "$JPEG/fuzz/cjpeg.cc"                cjpeg
build_jpeg compress_fuzzer            "$JPEG/fuzz/compress.cc"             tj
build_jpeg compress_yuv_fuzzer        "$JPEG/fuzz/compress_yuv.cc"         tj
build_jpeg compress_lossless_fuzzer   "$JPEG/fuzz/compress_lossless.cc"    tj
build_jpeg compress12_fuzzer          "$JPEG/fuzz/compress12.cc"           tj
build_jpeg compress12_lossless_fuzzer "$JPEG/fuzz/compress12_lossless.cc"  tj
build_jpeg compress16_lossless_fuzzer "$JPEG/fuzz/compress16_lossless.cc"  tj
build_jpeg libjpeg_turbo_fuzzer       "$JPEG/fuzz/decompress.cc"           tj
build_jpeg decompress_yuv_fuzzer      "$JPEG/fuzz/decompress_yuv.cc"       tj
build_jpeg transform_fuzzer           "$JPEG/fuzz/transform.cc"            tj

# ---------------------------------------------------------------- libpng
PNG_ARGS=(-DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF)
cmake_lib "$PNG" "$OUT/png-fuzz" "$FUZZ_CFLAGS" "${PNG_ARGS[@]}"
cmake_lib "$PNG" "$OUT/png-sa"   "$SA_CFLAGS"   "${PNG_ARGS[@]}"
cmake --build "$OUT/png-fuzz" -j"$MAYHEM_JOBS"
cmake --build "$OUT/png-sa"   -j"$MAYHEM_JOBS"
PNG_HARNESS="$PNG/contrib/oss-fuzz/libpng_read_fuzzer.cc"
$CXX $FUZZ_CFLAGS -std=c++11 -I"$PNG" -I"$OUT/png-fuzz" "$PNG_HARNESS" $LIB_FUZZING_ENGINE \
  "$OUT/lsan_off.o" "$OUT/png-fuzz/libpng16.a" -lz -lm -o "$SRC/libpng_read_fuzzer"
$CXX $SA_CFLAGS -std=c++11 -I"$PNG" -I"$OUT/png-sa" "$PNG_HARNESS" "$OUT/standalone_main.o" \
  "$OUT/lsan_off.o" "$OUT/png-sa/libpng16.a" -lz -lm -o "$SRC/libpng_read_fuzzer-standalone"

# ---------------------------------------------------------------- utf8proc
# utf8proc.c #includes utf8proc_data.c itself; the harness omits <stdlib.h> (malloc), hence -include.
# utf8proc.c is built with -fno-sanitize=pointer-overflow: its sizing pass calls
# utf8proc_decompose_char(uc, buffer + wpos, ...) with buffer == NULL and wpos == 0, which UBSan
# flags ("applying zero offset to null pointer") on every input, so the halting build aborted
# inside the first utf8proc_NFD() call and never reached the other normalize paths. ASan and the
# other UBSan checks stay on and halting.
for variant in fuzz sa; do
  if [ "$variant" = fuzz ]; then flags="$FUZZ_CFLAGS"; engine="$LIB_FUZZING_ENGINE"; out="$SRC/utf8proc_fuzzer"
  else flags="$SA_CFLAGS"; engine="$OUT/standalone_main.o"; out="$SRC/utf8proc_fuzzer-standalone"; fi
  $CC $flags -fno-sanitize=pointer-overflow -I"$UTF8" -c "$UTF8/utf8proc.c" -o "$OUT/utf8proc-$variant.o"
  $CC $flags -I"$UTF8" -include stdlib.h -c "$UTF8/test/fuzzer.c" -o "$OUT/utf8proc_fuzzer-$variant.o"
  $CC $flags "$OUT/utf8proc_fuzzer-$variant.o" "$OUT/utf8proc-$variant.o" \
    $engine "$OUT/lsan_off.o" -o "$out"
done

# ---------------------------------------------------------------- oracle build (project's NORMAL flags)
# Clean, unsanitized, non-fuzzer builds of the same libraries; mayhem/test.sh only RUNS these.
ORACLE_FLAGS="-O2 $COVERAGE_FLAGS"
cmake -S "$JPEG" -B "$OUT/jpeg-test" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
  "${JPEG_ARGS[@]}" -DWITH_TURBOJPEG=0 >/dev/null
cmake --build "$OUT/jpeg-test" -j"$MAYHEM_JOBS" --target cjpeg-static djpeg-static jpegtran-static

cmake -S "$PNG" -B "$OUT/png-test" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
  "${PNG_ARGS[@]}" >/dev/null
cmake --build "$OUT/png-test" -j"$MAYHEM_JOBS"
$CC $ORACLE_FLAGS -I"$PNG" -I"$OUT/png-test" "$PNG/pngtest.c" "$OUT/png-test/libpng16.a" -lz -lm \
  -o "$OUT/png-test/pngtest"

for t in case custom iterate misc valid; do
  $CC $ORACLE_FLAGS -I"$UTF8" "$UTF8/test/$t.c" "$UTF8/test/tests.c" "$UTF8/utf8proc.c" \
    -o "$OUT/utf8proc-test-$t"
done
