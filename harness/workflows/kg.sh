# workflows/kg.sh — Code Knowledge Graph workflows (deterministic, zero tokens).

wf_kg_build() {
    local out; out=$(kg_build "$YCA_PROJECT_DIR")
    emit result "$(jq -n --arg s "$out" '{ok:true,summary:$s}')"
}

wf_kg_stats() {
    kg_build "$YCA_PROJECT_DIR" >/dev/null 2>&1 || true
    local nodes edges
    nodes=$(kg_query "SELECT kind, COUNT(*) AS n FROM kg_nodes GROUP BY kind;")
    edges=$(kg_query "SELECT kind, COUNT(*) AS n FROM kg_edges GROUP BY kind;")
    printf '%s\n%s\n' "$nodes" "$edges" >&2
    emit result "$(jq -n --argjson n "${nodes:-[]}" --argjson e "${edges:-[]}" '{ok:true,summary:"knowledge graph stats",data:{nodes:$n,edges:$e}}')"
}

wf_register "kg.build" wf_kg_build 1 writes "" "Index the project into kg_nodes/kg_edges"
wf_register "kg.stats" wf_kg_stats 1 safe   "" "Rebuild + show knowledge-graph stats"
