#!/usr/bin/env bash
set -euo pipefail
awk '
/^total_order_value\(\) \{$/ { print; print "    sqlite3 \"$db\" \"SELECT SUM(amount) FROM orders;\""; skip=1; next }
skip && /^\}$/ { print; skip=0; next }
skip { next }
{ print }
' app.sh > app.sh.new && mv app.sh.new app.sh
