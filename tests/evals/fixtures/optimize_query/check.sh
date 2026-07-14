#!/usr/bin/env bash
# success = correct answer AND the N+1 pattern is gone (exactly one SELECT)
set -euo pipefail
[[ "$(bash app.sh)" == "total=6" ]]
[[ "$(grep -c 'SELECT' app.sh)" -eq 1 ]]
