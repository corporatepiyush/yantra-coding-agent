# register.sh — Master registration (sources all tool/workflow/lang modules)

# Source all tool modules (registers tools via tool_register)
for _f in "$YCA_DIR/harness/tools/"*.sh; do
    [[ -f "$_f" ]] && source "$_f"
done

# Source all language modules (registers language-specific tools)
for _f in "$YCA_DIR/harness/langs/"*.sh; do
    [[ -f "$_f" ]] && source "$_f"
done

# Source all workflow modules (registers workflows via wf_register)
for _f in "$YCA_DIR/harness/workflows/"*.sh; do
    [[ -f "$_f" ]] && source "$_f"
done
