# tools/security_dns.sh — DNS/hosts-level security (StevenBlack hosts blocklist)

# tool_sec_dns_hosts_status -> show current hosts file stats
tool_sec_dns_hosts_status() {
    local hosts_file
    hosts_file=$(os_hosts_file)
    if [[ ! -r "$hosts_file" ]]; then
        printf 'cannot read %s' "$hosts_file"
        return 1
    fi
    local lines entries
    lines=$(wc -l < "$hosts_file" | tr -d ' ')
    entries=$(grep -c '0.0.0.0\|127.0.0.1' "$hosts_file" 2>/dev/null || printf '0')
    printf 'hosts file: %s\nlines: %s\nblock entries: %s\n' "$hosts_file" "$lines" "$entries"
}

# tool_sec_dns_hosts_apply -> fetch StevenBlack hosts and apply (requires sudo)
tool_sec_dns_hosts_apply() {
    local hosts_file
    hosts_file=$(os_hosts_file)
    local url="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternatives/fakenews-gambling-porn-social/hosts"
    local tmpfile
    tmpfile=$(path_temp_file yca-hosts)

    logmsg "$(c_warn '⚠ This will replace your hosts file with extreme content blocking.')"
    logmsg "$(c_warn '  Blocks: fakenews, gambling, porn, social media domains.')"
    logmsg "$(c_warn '  Some sites may stop working. To undo: sec_dns_hosts_undo.')"

    confirm_action "Replace $hosts_file with StevenBlack blocklist" \
        "curl $url > $hosts_file" || { confirm_denied_msg; return 1; }

    logmsg "$(c_info 'Downloading hosts file...')"
    if ! http_download "$url" "$tmpfile"; then
        printf 'failed to download hosts file'
        return 1
    fi

    # Backup current hosts with timestamp
    local backup="${hosts_file}.yca-backup.$(now_stamp)"
    logmsg "$(c_info "Backing up current hosts → $backup")"
    sudo cp "$hosts_file" "$backup" 2>/dev/null || cp "$hosts_file" "$backup" 2>/dev/null || true
    # A verified backup is REQUIRED — sec_dns_hosts_undo restores from it. The old
    # `|| true` swallowed a failed backup and overwrote /etc/hosts anyway, leaving
    # nothing to undo. Abort unless we produced a non-empty backup.
    if [[ ! -s "$backup" ]]; then
        rm -f "$tmpfile"
        printf 'aborting: could not create a verified backup of %s (needed for sec_dns_hosts_undo)' "$hosts_file"
        return 1
    fi

    # Write new hosts file
    if os_sudo_available; then
        sudo cp "$tmpfile" "$hosts_file" && sudo chmod 644 "$hosts_file"
    else
        cp "$tmpfile" "$hosts_file" 2>/dev/null && chmod 644 "$hosts_file" 2>/dev/null
    fi
    rm -f "$tmpfile"

    local entries
    entries=$(grep -c '0.0.0.0' "$hosts_file" 2>/dev/null || printf '0')
    logmsg "$(c_ok "✓ Applied $entries block entries. DNS is now locked down.")"
    logmsg "$(c_dim '  To undo: sec_dns_hosts_undo')"
    printf 'applied %s block entries' "$entries"
}

# tool_sec_dns_hosts_undo -> restore last hosts backup
tool_sec_dns_hosts_undo() {
    local hosts_file
    hosts_file=$(os_hosts_file)
    local dir
    dir=$(dirname "$hosts_file")
    # Find newest backup
    local backup
    backup=$(ls -t "${hosts_file}.yca-backup."* 2>/dev/null | head -1)
    if [[ -z "$backup" ]]; then
        printf 'no backup found to restore'
        return 1
    fi
    confirm_action "Restore hosts from $backup" || { confirm_denied_msg; return 1; }
    if os_sudo_available; then
        sudo cp "$backup" "$hosts_file"
    else
        cp "$backup" "$hosts_file"
    fi
    logmsg "$(c_ok "✓ Restored hosts from $backup")"
    printf 'restored from %s' "$backup"
}

# tool_sec_dns_flush -> flush DNS cache
tool_sec_dns_flush() {
    case "$(os_detect)" in
        darwin)
            sudo dscacheutil -flushcache 2>/dev/null
            sudo killall -HUP mDNSResponder 2>/dev/null
            printf 'DNS cache flushed (macOS)'
            ;;
        linux)
            if command -v systemctl &>/dev/null; then
                sudo systemctl restart systemd-resolved 2>/dev/null
            fi
            sudo /etc/init.d/nscd restart 2>/dev/null || true
            printf 'DNS cache flushed (Linux)'
            ;;
        freebsd)
            sudo service named restart 2>/dev/null || true
            printf 'DNS cache flushed (FreeBSD)'
            ;;
    esac
}

tool_register "sec_dns_hosts_status" tool_sec_dns_hosts_status '{"type":"object","properties":{}}' safe all sec
tool_register "sec_dns_hosts_apply"  tool_sec_dns_hosts_apply  '{"type":"object","properties":{}}' destructive all sec
tool_register "sec_dns_hosts_undo"   tool_sec_dns_hosts_undo   '{"type":"object","properties":{}}' writes all sec
tool_register "sec_dns_flush"        tool_sec_dns_flush        '{"type":"object","properties":{}}' writes all sec
