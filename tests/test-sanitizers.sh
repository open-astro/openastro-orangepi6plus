#!/bin/bash
# Check that combined ASan+UBSan initializes and detects both kinds of error.
set -euo pipefail

COMPILER="${CC:-cc}"
command -v "$COMPILER" >/dev/null || {
    echo 'Compiler missing. Install build-essential on the test machine first.' >&2
    exit 1
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/openastro-sanitizers-XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

cat > "$WORK/smoke.c" <<'EOF'
#include <limits.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    volatile int *value = malloc(sizeof(*value));
    if (!value) return 2;
    value[0] = 42;
    if (argc > 1 && argv[1][0] == 'a') {
        free((void *)value);
        value[0] = 7; /* Intentional use-after-free: ASan must reject it. */
        return 1;
    }
    if (argc > 1 && argv[1][0] == 'u') {
        volatile int maximum = INT_MAX;
        volatile int overflow = maximum + 1; /* UBSan must reject it. */
        (void)overflow;
    }
    int result = value[0] != 42;
    free((void *)value);
    return result;
}
EOF

uname -m
"$COMPILER" --version | head -n 1
"$COMPILER" -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
    -fno-sanitize-recover=all "$WORK/smoke.c" -o "$WORK/smoke"
export ASAN_OPTIONS=halt_on_error=1:detect_leaks=1
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
"$WORK/smoke"

expect_failure() {
    local mode="$1" diagnostic="$2"
    if "$WORK/smoke" "$mode" > "$WORK/$mode.log" 2>&1; then
        echo "Sanitizer missed the intentional $mode error." >&2
        exit 1
    fi
    if ! grep -F "$diagnostic" "$WORK/$mode.log" >/dev/null; then
        cat "$WORK/$mode.log" >&2
        echo "Unexpected failure instead of the expected sanitizer diagnostic." >&2
        exit 1
    fi
}
expect_failure a 'AddressSanitizer: heap-use-after-free'
expect_failure u 'runtime error: signed integer overflow'
echo 'Combined ASan+UBSan passed: clean execution, use-after-free detection, and signed-overflow detection.'
