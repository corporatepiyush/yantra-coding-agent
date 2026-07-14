#!/usr/bin/env bash
set -euo pipefail
awk '
/^route\(\) \{$/ { print "handle_products() {"; print "    echo \"products: ok\""; print "}"; print "" }
{ print }
/^        orders\) handle_orders ;;$/ { print "        products) handle_products ;;" }
' handlers.sh > handlers.sh.new && mv handlers.sh.new handlers.sh
