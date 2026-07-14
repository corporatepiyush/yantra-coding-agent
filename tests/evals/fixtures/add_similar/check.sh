#!/usr/bin/env bash
# success = a products handler exists, is routed, and follows the convention
set -euo pipefail
source ./handlers.sh
[[ "$(route products)" == "products: ok" ]]
[[ "$(route users)" == "users: ok" ]]
[[ "$(route orders)" == "orders: ok" ]]
