# Source this file from an interactive Warp zsh to register its pane with Muster.
[[ -o interactive && $TERM_PROGRAM == WarpTerminal && -n ${WARP_FOCUS_URL:-} ]] || return 0

() {
    emulate -L zsh
    local pane=${WARP_FOCUS_URL#warp://session/}
    [[ $WARP_FOCUS_URL == warp://session/* && ${#pane} == 32 && $pane != *[^0-9a-f]* ]] || return 0
    local dir="$HOME/Library/Caches/Muster/warp-panes"
    local started epoch tmp
    started=$(LC_ALL=C TZ=UTC /bin/ps -p $$ -o lstart=) || return 0
    epoch=$(LC_ALL=C TZ=UTC /bin/date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null) || return 0
    /bin/mkdir -p -m 700 "$dir" || return 0
    tmp=$(/usr/bin/mktemp "$dir/.pane.XXXXXXXX") || return 0
    print -rn -- "$pane" >| "$tmp" && /bin/mv -f "$tmp" "$dir/$$.$epoch" || /bin/rm -f "$tmp"
    typeset -g _muster_warp_pane_file="$dir/$$.$epoch"
    autoload -Uz add-zsh-hook
    _muster_remove_warp_pane() { /bin/rm -f "$_muster_warp_pane_file"; }
    add-zsh-hook zshexit _muster_remove_warp_pane
}
