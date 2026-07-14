#!/usr/bin/env bash
set -euo pipefail
source ./calc.sh
[[ "$(add 2 3)" == "5" ]] || { echo "FAIL: add 2 3 = $(add 2 3), want 5"; exit 1; }
[[ "$(add -1 1)" == "0" ]] || { echo "FAIL: add -1 1 = $(add -1 1), want 0"; exit 1; }
echo ok
