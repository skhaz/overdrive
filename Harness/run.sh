#!/bin/zsh
set -u
cd "${0:A:h}/.."

CYCLES=${CYCLES:-20}
IDLE=${IDLE:-30}
SPIKE=${SPIKE:-90}
OUT=${OUT:-.build/harness/out}
AX=.build/harness/ax
APP=$PWD/Overdrive.app

rm -rf "$OUT" && mkdir -p "$OUT/samples"
mkdir -p .build/harness
swiftc -O Harness/ax.swift -o "$AX" || exit 1
[[ -n ${SKIP_BUILD:-} ]] || ./build.sh >/dev/null || exit 1

installed=$(pgrep -f /Applications/Overdrive.app/Contents/MacOS/Overdrive)
pkill -x Overdrive
sleep 2
started=$(date +%s)
open -g --env MallocStackLogging=1 "$APP"
until "$AX" pages >/dev/null 2>&1; do sleep 1; (( $(date +%s) - started > 60 )) && { echo "FAIL: no window after 60 s"; exit 1; }; done
pid=$(pgrep -f "$APP/Contents/MacOS/Overdrive")
echo "pid $pid"

failures=0
fail() { echo "FAIL: $*" | tee -a "$OUT/failures.txt"; failures=$((failures + 1)); }

(
    hot=0
    while kill -0 $pid 2>/dev/null; do
        line=$(ps -o rss=,%cpu= -p $pid) || break
        echo "$(date +%s) $line" >> "$OUT/usage.txt"
        cpu=${${line##* }%.*}
        if (( cpu >= SPIKE )); then hot=$((hot + 1)); else hot=0; fi
        if (( hot == 3 )); then sample $pid 2 -file "$OUT/samples/$(date +%H%M%S).txt" >/dev/null 2>&1; fi
        sleep 1
    done
) &
monitor=$!

footprint() {
    /usr/bin/footprint -p $pid 2>/dev/null | awk '
        function mb(value, unit) { return unit == "GB" ? value * 1024 : unit == "KB" ? value / 1024 : unit == "B" ? value / 1048576 : value }
        /Footprint:/ { for (i = 1; i < NF; i++) if ($i == "Footprint:") total = mb($(i + 1), $(i + 2)) }
        /Performance Tool Data/ { tool = mb($1, $2) }
        END { printf "%.0fMB", total - tool }'
}

step() {
    local begin=$(date +%s)
    "$AX" "$@" > /dev/null 2>&1
    local took=$(( $(date +%s) - begin ))
    kill -0 $pid 2>/dev/null || { fail "crash after: $*"; return 1; }
    (( took >= 5 )) && fail "hang ${took} s on: $*"
    sleep ${PAUSE:-0.6}
    return 0
}

expect() {
    local got=$("$AX" "$1")
    [[ $got == $2 ]] || fail "$3: $1 is '$got', expected '$2'"
}

pages=("${(@f)$("$AX" pages)}")
playlists=(${pages[5,-1]})
volume=$("$AX" volume)
"$AX" volume 0 > /dev/null
words=(a ar are "" e en end "" o on one "on e" "" z zq zqx "")

for cycle in $(seq $CYCLES); do
    step select Albums || break
    step album $((cycle % 7)) || break
    expect lyrics shown "album shows the lyrics"
    step press Play || break
    step press Next || break
    step press Back || break
    expect lyrics hidden "the Albums grid hides the lyrics"

    step select Artists || break
    step row $cycle || break

    step select Songs || break
    step row $((cycle * 37)) || break
    expect lyrics shown "Songs shows the lyrics"
    for word in $words; do step search "$word" || break 2; done
    step search "" || break

    step select "Liked Songs" || break
    step row $cycle || break
    step row -1 || break
    for playlist in $playlists; do step select "$playlist" || break 2; step row $cycle || break 2; done

    step press "Show in a Floating Window" || break
    step select Albums || break
    step dock || break
    step press Next || break
    step press Next || break
    step press Previous || break

    echo "cycle $cycle footprint $(footprint)" | tee -a "$OUT/footprint.txt"
done

step press Pause
sleep $IDLE
idle_paused=$(awk -v t=$(( $(date +%s) - IDLE + 5 )) '$1 >= t { s += $3; n++ } END { if (n) printf "%.1f", s / n; else print 0 }' "$OUT/usage.txt")
step press Play
sleep $IDLE
idle_playing=$(awk -v t=$(( $(date +%s) - IDLE + 5 )) '$1 >= t { s += $3; n++ } END { if (n) printf "%.1f", s / n; else print 0 }' "$OUT/usage.txt")
step press Pause

if kill -0 $pid 2>/dev/null; then
    leaks $pid > "$OUT/leaks.txt" 2>&1
    leaked=$(awk '/leaks for/ { print $3; exit }' "$OUT/leaks.txt")
    (( ${leaked:-0} > 0 )) && fail "$leaked leaks, see $OUT/leaks.txt"
fi

crashes=$(find ~/Library/Logs/DiagnosticReports -name 'Overdrive*' -newermt "@$started" 2>/dev/null)
[[ -n $crashes ]] && fail "crash reports: $crashes"

spikes=$(ls "$OUT/samples" | wc -l | tr -d ' ')
(( spikes > 0 )) && fail "$spikes CPU spikes of 3 s or more at ${SPIKE}% or more, see $OUT/samples"

kill $monitor 2>/dev/null
"$AX" volume "$volume" > /dev/null
pkill -f "$APP/Contents/MacOS/Overdrive"
[[ -n $installed ]] && open -g /Applications/Overdrive.app

first=$(head -1 "$OUT/footprint.txt" | awk '{ print $4 }')
last=$(tail -1 "$OUT/footprint.txt" | awk '{ print $4 }')
peak=$(awk '{ if ($2 > m) m = $2 } END { printf "%.0f MB", m / 1024 }' "$OUT/usage.txt")
echo "footprint: $first after the first cycle, $last after the last cycle, peak RSS $peak"
echo "CPU at rest: ${idle_paused}% paused, ${idle_playing}% playing"
echo "failures: $failures"
(( failures == 0 ))
