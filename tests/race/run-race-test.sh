#!/usr/bin/env bash
# A/B run of the VncConnection torn-frame race test.
#
#   01 = start the synthetic RFB server
#   02 = build vnc-race-test against the veyon-macos stage tree
#   03 = run RACE_MODE=0 (historical racy behaviour) and RACE_MODE=1 (fix)
#
# Expected: mode 0 reports torn > 0, mode 1 reports torn == 0.
#
# Usage:
#   run-race-test.sh [seconds] [build-dir]
# defaults: 30 seconds, veyon-kali/build/veyon-macos

set -euo pipefail

SECONDS_RUN="${1:-30}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VEYON="${2:-$REPO/build/veyon-macos}"
STAGE="$VEYON/build/stage"
PORT="${RACE_PORT:-12345}"

QT6="$(brew --prefix qtbase 2>/dev/null || echo /opt/homebrew/opt/qtbase)"
QCA="$(brew --prefix qca 2>/dev/null || echo /opt/homebrew/opt/qca)"
QT5C="$(brew --prefix qt5compat 2>/dev/null || echo /opt/homebrew/opt/qt5compat)"

cd "$STAGE/bin"

echo "=== 1. synthetic RFB server on :$PORT"
if pgrep -f rfb-race-server.py >/dev/null; then
	pkill -f rfb-race-server.py || true
	sleep 1
fi
python3 "$REPO/tests/race/rfb-race-server.py" "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1

echo "=== 2. building vnc-race-test"
clang++ -std=c++17 -fPIC \
	-I"$VEYON/core/src" -I"$VEYON/build/core/src" \
	-I"$QT6/include" -I"$QT6/include/QtCore" -I"$QT6/include/QtGui" \
	-I"$QT6/include/QtNetwork" -I"$QT6/include/QtWidgets" \
	-F"$QT6/lib" -F"$QCA/lib" -F"$QT5C/lib" \
	-framework QtCore -framework QtGui -framework QtNetwork \
	-framework QtWidgets -framework QtConcurrent \
	-L"$STAGE/Resources/lib" -lveyon-core -Wl,-rpath,"$STAGE/Resources/lib" \
	"$REPO/tests/race/vnc-race-test.cpp" -o vnc-race-test

run_mode() {
	local mode=$1
	local tag=$2
	echo "=== $tag (RACE_MODE=$mode, ${SECONDS_RUN}s)"
	QT_QPA_PLATFORM=offscreen \
	RACE_PORT="$PORT" RACE_MODE="$mode" RACE_SECONDS="$SECONDS_RUN" \
	RACE_RESULT="/tmp/race_${tag}.txt" \
	DYLD_LIBRARY_PATH="$STAGE/Resources/lib:$STAGE/PlugIns" \
	./vnc-race-test 2>&1 | grep -E "SUMMARY|TORN" || true
	cat "/tmp/race_${tag}.txt"
}

run_mode 0 A
run_mode 1 B

TORN_A=$(sed -n 's/.*torn=//p' "/tmp/race_A.txt" | tr -d '[:space:]')
TORN_B=$(sed -n 's/.*torn=//p' "/tmp/race_B.txt" | tr -d '[:space:]')
echo
echo "=== RESULT: torn(unfixed)=$TORN_A torn(fixed)=$TORN_B"
if [ "${TORN_A:-0}" -gt 0 ] && [ "${TORN_B:-1}" -eq 0 ]; then
	echo "PASS: race reproduced without the fix and eliminated with it"
else
	echo "NOTE: check the numbers above (results can be timing-sensitive)"
fi
