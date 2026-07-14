# tools/plan.sh — Plan store (T12): tools + result decoration
#
# A plan is one row in the `tasks` table (agent='plan'). Its steps live in that
# row's input_json as {"steps":[{"order":N,"text":"...","done":bool},...]} — a
# single source of truth per plan, so plan isolation is structural: every read
# and write keys on the plan's own row id. Cross-project isolation is automatic
# because each project has its own .harness.db.
#
# Durability for small models (a known small-model failure mode): while a plan is active,
# plan_decorate appends exactly one `PLAN: step N of M — <text>` line to every
# host-facing tool result (see tool_dispatch). Decoration is computed at result
# time from the DB and is NEVER persisted — nothing writes a `PLAN:` line into
# events, plan rows, or spilled files.
#
# Provides: plan_create, plan_status, plan_step_done, plan_decorate.

# _plan_active_id -> the id of the most-recent active plan, or "" if none.
# Ordered by id DESC (monotonic) — created_ts has only second granularity and
# ties are ambiguous.
_plan_active_id() {
    [[ -n "${YCA_DB_PATH:-}" && -f "$YCA_DB_PATH" ]] || { printf ''; return 0; }
    _sqlite "$YCA_DB_PATH" \
        "SELECT id FROM tasks WHERE agent='plan' AND status='active' ORDER BY id DESC LIMIT 1;" \
        2>/dev/null || printf ''
}

# tool_plan_create — create a plan. Input: {steps:[{order?,text},...]} or
# {steps:["text",...]}. Returns {ok, plan_id}.
tool_plan_create() {
    local args_json="${5:-${YCA_TOOL_ARGS_JSON:-}}"

    # Normalize steps: accept objects {order,text} or bare strings; assign a
    # contiguous 1-based order when absent; every step starts not-done.
    local steps
    steps=$(printf '%s' "$args_json" | jq -c '
        (.steps // empty)
        | if type != "array" or length == 0 then error("empty") else . end
        | to_entries
        | map({ order: (((if (.value|type) == "object" then .value.order else null end) // (.key + 1)) | tonumber),
                text:  (if (.value|type) == "string" then .value else (.value.text // "") end),
                done:  false })' 2>/dev/null) \
        || { printf '{"ok":false,"error":"steps must be a non-empty array"}'; return 1; }

    local input_json
    input_json=$(jq -cn --argjson s "$steps" '{steps:$s}')

    local plan_id
    plan_id=$(_sqlite "$YCA_DB_PATH" 2>/dev/null <<SQL
INSERT INTO tasks(agent, status, input_json) VALUES ('plan', 'active', '$(printf '%s' "$input_json" | sed "s/'/''/g")');
SELECT last_insert_rowid();
SQL
    )
    [[ -n "$plan_id" && "$plan_id" != "0" ]] \
        || { printf '{"ok":false,"error":"database error"}'; return 1; }

    printf '{"ok":true,"plan_id":%d,"data":{"plan_id":%d,"steps":%s}}' \
        "$plan_id" "$plan_id" "$steps"
}

# tool_plan_status — Input: {plan_id?}. Defaults to the active plan.
# Returns {ok, plan_id, steps, total, done_count, current_step}.
tool_plan_status() {
    local args_json="${5:-${YCA_TOOL_ARGS_JSON:-}}"
    local plan_id
    plan_id=$(printf '%s' "$args_json" | jq -r '.plan_id // empty' 2>/dev/null)
    [[ -n "$plan_id" ]] || plan_id=$(_plan_active_id)
    [[ -n "$plan_id" ]] || { printf '{"ok":true,"plan_id":null,"steps":[],"current_step":null}'; return 0; }

    local input_json
    input_json=$(_sqlite "$YCA_DB_PATH" \
        "SELECT input_json FROM tasks WHERE id=$plan_id AND agent='plan';" 2>/dev/null)
    [[ -n "$input_json" ]] || { printf '{"ok":false,"error":"plan %d not found"}' "$plan_id"; return 1; }

    printf '%s' "$input_json" | jq -c --argjson id "$plan_id" '
        (.steps // []) as $s
        | ($s | map(select(.done == false)) | .[0]) as $cur
        | { ok: true, plan_id: $id, steps: $s, total: ($s|length),
            done_count: ($s | map(select(.done)) | length),
            current_step: (if $cur == null then null
                           else { order: $cur.order, text: $cur.text,
                                   n: (($s | map(.done) | index(false)) + 1) } end) }'
}

# tool_plan_step_done — Input: {plan_id?, step_order}. Marks the step done;
# flips the plan to 'completed' when every step is done. Returns {ok, ...}.
tool_plan_step_done() {
    local args_json="${5:-${YCA_TOOL_ARGS_JSON:-}}"
    local plan_id step_order
    plan_id=$(printf '%s' "$args_json" | jq -r '.plan_id // empty' 2>/dev/null)
    step_order=$(printf '%s' "$args_json" | jq -r '.step_order // empty' 2>/dev/null)
    [[ -n "$plan_id" ]] || plan_id=$(_plan_active_id)
    [[ -n "$plan_id" && -n "$step_order" ]] \
        || { printf '{"ok":false,"error":"step_order required (and no active plan)"}'; return 1; }

    local input_json
    input_json=$(_sqlite "$YCA_DB_PATH" \
        "SELECT input_json FROM tasks WHERE id=$plan_id AND agent='plan';" 2>/dev/null)
    [[ -n "$input_json" ]] || { printf '{"ok":false,"error":"plan %d not found"}' "$plan_id"; return 1; }

    # Mark the matching step done. Unknown order → error, not a silent no-op.
    local updated
    updated=$(printf '%s' "$input_json" | jq -ce --argjson ord "$step_order" '
        if (.steps | map(.order) | index($ord)) == null then error("no such step")
        else .steps |= map(if .order == $ord then .done = true else . end) end' 2>/dev/null) \
        || { printf '{"ok":false,"error":"no step with order %s"}' "$step_order"; return 1; }

    local all_done new_status
    all_done=$(printf '%s' "$updated" | jq -r '(.steps | all(.done))')
    new_status=$([[ "$all_done" == "true" ]] && printf 'completed' || printf 'active')

    _sqlite "$YCA_DB_PATH" 2>/dev/null <<SQL || { printf '{"ok":false,"error":"database error"}'; return 1; }
UPDATE tasks SET input_json='$(printf '%s' "$updated" | sed "s/'/''/g")',
  status='$new_status', updated_ts=datetime('now') WHERE id=$plan_id;
SQL

    printf '{"ok":true,"plan_id":%d,"step_order":%d,"completed":%s}' \
        "$plan_id" "$step_order" "$all_done"
}

# plan_decorate TEXT — append exactly one `PLAN: step N of M — <text>` line while
# a plan is active. No active plan, or YCA_PLAN_DECORATE=0 → TEXT is returned
# byte-identical. Computed from the DB at call time; never persisted.
plan_decorate() {
    local text="$1"
    [[ "${YCA_PLAN_DECORATE:-1}" == "0" ]] && { printf '%s' "$text"; return 0; }
    local plan_id
    plan_id=$(_plan_active_id)
    [[ -n "$plan_id" ]] || { printf '%s' "$text"; return 0; }

    local line
    line=$(_sqlite "$YCA_DB_PATH" \
        "SELECT input_json FROM tasks WHERE id=$plan_id;" 2>/dev/null \
        | jq -r '
            (.steps // []) as $s
            | ($s | map(.done) | index(false)) as $i
            | if $i == null then empty
              else "PLAN: step \($i + 1) of \($s|length) — \($s[$i].text)" end' 2>/dev/null)
    [[ -n "$line" ]] || { printf '%s' "$text"; return 0; }
    printf '%s\n%s' "$text" "$line"
}

# Register (schemas carry per-property descriptions per T6). Danger = `safe`:
# these tools mutate ONLY Yantra's own plan bookkeeping in SQLite — no user file,
# cloud, or system side effect — so they need no consent gate. Gating them would
# make the plan store unusable over MCP (where consent is elicitation, not yet
# built), defeating T12's goal that plan durability work on any host.
tool_register "plan_create" tool_plan_create '{"description":"Create a plan the session should follow; steps re-surface on every result while active","type":"object","properties":{"steps":{"type":"array","description":"ordered plan steps, each an object {order,text} or a bare string"}},"required":["steps"]}' safe all core
tool_register "plan_status" tool_plan_status '{"description":"Show the active plan (or a plan by id) and which step is current","type":"object","properties":{"plan_id":{"type":"integer","description":"plan id; omit to use the most recent active plan"}},"required":[]}' safe all core
tool_register "plan_step_done" tool_plan_step_done '{"description":"Mark a plan step complete; completing the last step closes the plan","type":"object","properties":{"plan_id":{"type":"integer","description":"plan id; omit to use the active plan"},"step_order":{"type":"integer","description":"the order number of the step to mark done"}},"required":["step_order"]}' safe all core
