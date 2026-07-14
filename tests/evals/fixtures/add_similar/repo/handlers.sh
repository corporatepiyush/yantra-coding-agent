handle_users() {
    echo "users: ok"
}

handle_orders() {
    echo "orders: ok"
}

route() {
    case "$1" in
        users) handle_users ;;
        orders) handle_orders ;;
        *) echo "unknown route: $1" >&2; return 1 ;;
    esac
}
