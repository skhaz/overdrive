#!/bin/sh
set -e
cd "$(dirname "$0")/.."
SECONDS_PER_TARGET=${1:-300}
SOURCES="Sources/Overdrive/MP4.swift Sources/Overdrive/ID3.swift Sources/Overdrive/MPEG.swift Sources/Overdrive/Embedded.swift Sources/Overdrive/LRC.swift"
OUT=${OUT:-/tmp/fuzz}
mkdir -p "$OUT/bin"

for target in mp4 id3 mpeg flac lrc; do
    swiftc -O -g -parse-as-library -sanitize=fuzzer,address -o "$OUT/bin/$target" $SOURCES Fuzz/Targets/File.swift "Fuzz/Targets/$target.swift"
done

for target in mp4 id3 mpeg flac lrc; do
    mkdir -p "$OUT/corpus/$target" "$OUT/crashes/$target"
    [ -d "Fuzz/Seeds/$target" ] && cp -n Fuzz/Seeds/$target/* "$OUT/corpus/$target/" 2>/dev/null || true
    echo "== $target"
    "$OUT/bin/$target" "$OUT/corpus/$target" -artifact_prefix="$OUT/crashes/$target/" -max_total_time="$SECONDS_PER_TARGET" -max_len=262144 -timeout=10 -rss_limit_mb=4096 -print_final_stats=1 2>&1 | grep -E "^#|ERROR|SUMMARY|artifact|Done|stat::" | tail -12 || true
done
