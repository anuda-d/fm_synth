#!/bin/bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_dir/build/dsp-tests"
compiler="${DSP_CXX:-/Library/Developer/CommandLineTools/usr/bin/clang++}"
export DEVELOPER_DIR="${DSP_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
sdk_path="$(/usr/bin/xcrun --show-sdk-path)"

compile_flags=(-std=c++17 -O3 -DNDEBUG -Wall -Wextra -Wpedantic -Werror -pthread)
test_args=()
binary_name="dsp-tests"
for argument in "$@"; do
    case "$argument" in
        --asan)
            compile_flags=(-std=c++17 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread -fsanitize=address,undefined -fno-omit-frame-pointer)
            binary_name="dsp-tests-asan"
            ;;
        --tsan)
            compile_flags=(-std=c++17 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread -fsanitize=thread -fno-omit-frame-pointer)
            binary_name="dsp-tests-tsan"
            ;;
        --ubsan)
            compile_flags=(-std=c++17 -O1 -g -Wall -Wextra -Wpedantic -Werror -pthread -fsanitize=undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
            binary_name="dsp-tests-ubsan"
            ;;
        --help)
            cat <<'HELP'
Compile the standalone DSP harness with Apple's Command Line Tools, then run it.
Usage: scripts/test-dsp.sh [--asan | --tsan | --ubsan] [--no-benchmark] [--no-stress]
       scripts/test-dsp.sh --benchmark-only
       scripts/test-dsp.sh --tsan --stress-only

Default: numeric/audio regression checks, concurrency stress, release benchmark.
--asan enables address and undefined-behavior sanitizers.
--tsan enables the thread sanitizer; runtime support depends on the host macOS.
--ubsan enables undefined-behavior checks independently of the ASan runtime.
Do not compare sanitizer benchmark timings with release timings.
DSP_CXX and DSP_DEVELOPER_DIR can override the compiler and developer directory.
No dependencies are downloaded. Build artifacts are written under build/.
HELP
            exit 0
            ;;
        *) test_args+=("$argument") ;;
    esac
done

mkdir -p "$output_dir"
"$compiler" "${compile_flags[@]}" -isysroot "$sdk_path" -I "$repo_dir/src/CDSP/include" \
    "$repo_dir/Tests/DSPTests.cpp" "$repo_dir/src/CDSP/FMSynth.cpp" \
    -o "$output_dir/$binary_name"
if ((${#test_args[@]})); then
    "$output_dir/$binary_name" "${test_args[@]}"
else
    "$output_dir/$binary_name"
fi
