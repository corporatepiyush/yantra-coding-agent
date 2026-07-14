#!/usr/bin/env bash
set -euo pipefail
db=$(mktemp)
trap 'rm -f "$db"' EXIT
sqlite3 "$db" "CREATE TABLE orders (id INTEGER PRIMARY KEY, amount INTEGER);"
sqlite3 "$db" "INSERT INTO orders (amount) VALUES (1),(2),(3);"

total_order_value() {
    local total=0 i
    for i in $(sqlite3 "$db" "SELECT id FROM orders;"); do
        total=$(( total + $(sqlite3 "$db" "SELECT amount FROM orders WHERE id = $i;") ))
    done
    echo "$total"
}

echo "total=$(total_order_value)"
