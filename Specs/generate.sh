#!/bin/zsh
# Regenerate the C that Ponte compiles from the t27 specs, and run every spec's own tests.
#   T27C=/path/to/t27c ./Specs/generate.sh
# The generated C is committed, so building the app (swift build, scripts/bundle.sh) never needs t27c.
# Sources/PonteSpecs/<spec>.h is the full output of t27c gen-c (bodies and tests, compiled once by
# Sources/PonteSpecs/t27_specs.c); Sources/PonteSpecs/include/<spec>.api.h is its constants and
# prototypes, which Swift imports through include/ponte_specs.h. Specs/T27C_PIN names the t27c the
# committed C was generated with.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
T27C="${T27C:-$HOME/Documents/t27-v051/target/release/t27c}"
SPECS_DIR="$ROOT_DIR/Specs"
OUT="$ROOT_DIR/Sources/PonteSpecs"
INCLUDE="$OUT/include"
WORK="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$WORK"' EXIT
[[ -x "$T27C" ]] || { print -u2 "t27c not found: set T27C"; exit 2; }
/bin/mkdir -p "$INCLUDE"

# Copy a file only when its content changed, so builds see no new timestamps.
update() { /usr/bin/cmp -s "$1" "$2" || /bin/cp "$1" "$2"; }

# Byte tables and test texts are written into their specs from readable lists first.
for TABLES in "$SPECS_DIR"/tables/*.py; do /usr/bin/python3 "$TABLES" >/dev/null; done

# Guards over the whole tree: the parser must consume every spec completely (a silently dropped tail
# loses functions or tests), and every call must match its callee's signature.
"$T27C" parse-complete --specs-dir "$SPECS_DIR" > "$WORK/parse.txt"
for FIELD in "parse but TRUNCATE" "parse but DISCARD" "do not parse"; do
  /usr/bin/grep -Eq "^ *$FIELD +0( |\$)" "$WORK/parse.txt" || { /bin/cat "$WORK/parse.txt" >&2; print -u2 "parse-complete: $FIELD"; exit 1; }
done
"$T27C" check-calls --specs-dir "$SPECS_DIR" > "$WORK/calls.txt"
/usr/bin/grep -Eq "^ *TOTAL +0\$" "$WORK/calls.txt" || { /bin/cat "$WORK/calls.txt" >&2; exit 1; }

SPEC_FILES=("$SPECS_DIR"/*.t27)
TOTAL_TESTS=0
for SPEC in $SPEC_FILES; do
  NAME="${SPEC:t:r}"
  "$T27C" check "$SPEC" > "$WORK/$NAME.check"
  # Typecheck warnings do not stop the build, but are shown.
  /usr/bin/sed -n "s/^ *- warning: /  $NAME warning: /p" "$WORK/$NAME.check"
  "$T27C" gen-c "$SPEC" > "$WORK/$NAME.h"
  /bin/cp "$WORK/$NAME.h" "$WORK/$NAME-test.c"
  # The warnings Xcode turns on, as errors; -ffp-contract=off as in the app build (no fused multiply-add).
  xcrun clang -std=c11 -ffp-contract=off -Wall -Wshorten-64-to-32 -Wno-parentheses-equality -Werror -DT27_TEST_MAIN \
    "$WORK/$NAME-test.c" -o "$WORK/$NAME-test" -lm
  RESULT="$("$WORK/$NAME-test")"
  RAN="${${RESULT#All }%% tests passed.*}"
  WRITTEN="$(/usr/bin/grep -c '^test ' "$SPEC")"
  [[ "$RAN" == "$WRITTEN" ]] || { print -u2 "$NAME: $RAN tests ran, $WRITTEN written"; exit 1; }
  print "$NAME: $RAN tests passed"
  TOTAL_TESTS=$((TOTAL_TESTS + RAN))
  update "$WORK/$NAME.h" "$OUT/$NAME.h"
  # Swift compiles any function body it sees in a header, so Swift gets only the constants and the
  # prototypes; the bodies are compiled once from t27_specs.c.
  /usr/bin/awk '
    /^   Function implementations/ { print "/* Function bodies: see the full header. */"; print "#endif"; exit }
    { if (held != "") print held; held = $0 }
  ' "$WORK/$NAME.h" > "$WORK/$NAME.api.h"
  update "$WORK/$NAME.api.h" "$INCLUDE/$NAME.api.h"
done

# The umbrella header Swift imports, and the single C file that compiles the bodies, list every spec.
{
  print "// Decisions written in t27 (Specs/*.t27), compiled to C by t27c. Rewritten by Specs/generate.sh."
  print "#pragma once"
  for SPEC in $SPEC_FILES; do print "#include \"${SPEC:t:r}.api.h\""; done
} > "$WORK/ponte_specs.h"
{
  print "// Emits the function bodies of the generated t27 headers once. Rewritten by Specs/generate.sh."
  print "// t27c writes every condition in double parentheses: if ((a == b)). Package.swift passes no warning"
  print "// flags, so the warning generate.sh turns off with -Wno-parentheses-equality is turned off here."
  print "#pragma clang diagnostic ignored \"-Wparentheses-equality\""
  for SPEC in $SPEC_FILES; do print "#include \"${SPEC:t:r}.h\""; done
} > "$WORK/t27_specs.c"
update "$WORK/ponte_specs.h" "$INCLUDE/ponte_specs.h"
update "$WORK/t27_specs.c" "$OUT/t27_specs.c"
print "${#SPEC_FILES} specs, $TOTAL_TESTS tests passed; generated into ${OUT#$ROOT_DIR/}"
