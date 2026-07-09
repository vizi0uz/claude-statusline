#!/bin/bash

# Read JSON from stdin
json=$(cat)

# Parse using jq
model=$(echo "$json" | jq -r '.model.display_name // empty')
effort=$(echo "$json" | jq -r '.effort.level // empty')
used=$(echo "$json" | jq -r '.context_window.used_percentage // empty')
session_id=$(echo "$json" | jq -r '.session_id // empty')
rate_used=$(echo "$json" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rate_resets=$(echo "$json" | jq -r '.rate_limits.five_hour.resets_at // empty')

account_plan=""
account_email=""
public_ip=""
lan_ip=""

# Cache directory and file
cache_dir="${TMPDIR:-/tmp}"
cache_file="$cache_dir/claude-statusline-account-$session_id.json"
config_file="$HOME/.claude/statusline-config.json"

# IP refresh interval (seconds): env var > ~/.claude/statusline-config.json > default
ip_refresh_seconds="$CLAUDE_STATUSLINE_IP_REFRESH_SECONDS"
if [[ -z "$ip_refresh_seconds" ]] && [[ -f "$config_file" ]]; then
    ip_refresh_seconds=$(jq -r '.ipRefreshSeconds // empty' "$config_file" 2>/dev/null)
fi
[[ "$ip_refresh_seconds" =~ ^[0-9]+$ ]] || ip_refresh_seconds=60

# Account info refresh interval (seconds): env var > ~/.claude/statusline-config.json > default.
# Unlike the IP check, this re-check spawns `claude auth status`, so the
# default mirrors ip_refresh_seconds rather than being shorter.
account_refresh_seconds="$CLAUDE_STATUSLINE_ACCOUNT_REFRESH_SECONDS"
if [[ -z "$account_refresh_seconds" ]] && [[ -f "$config_file" ]]; then
    account_refresh_seconds=$(jq -r '.accountRefreshSeconds // empty' "$config_file" 2>/dev/null)
fi
[[ "$account_refresh_seconds" =~ ^[0-9]+$ ]] || account_refresh_seconds=60

# Best-effort LAN IP: ask the OS which local address it would route outbound
# traffic from. This stays correct with multiple NICs/VPNs/Docker bridges,
# unlike enumerating all local addresses. It's a local routing-table lookup
# (no packets sent), so it's cheap enough to compute fresh every render.
get_lan_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if [[ -z "$ip" ]] && command -v route >/dev/null 2>&1 && command -v ifconfig >/dev/null 2>&1; then
        local iface
        iface=$(route get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2}')
        if [[ -n "$iface" ]]; then
            ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
        fi
    fi
    if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# Only fetch identity-related data if the flag is explicitly enabled
if [[ "$CLAUDE_STATUSLINE_SHOW_IDENTITY" == "1" ]]; then
    lan_ip=$(get_lan_ip)
fi

if [[ "$CLAUDE_STATUSLINE_SHOW_IDENTITY" == "1" ]] && [[ -n "$session_id" ]]; then
    cache=""
    if [[ -f "$cache_file" ]]; then
        cache=$(cat "$cache_file" 2>/dev/null)
    fi

    account_plan=$(echo "$cache" | jq -r '.plan // empty' 2>/dev/null)
    account_email=$(echo "$cache" | jq -r '.email // empty' 2>/dev/null)
    account_checked_at=$(echo "$cache" | jq -r '.accountCheckedAt // 0' 2>/dev/null)
    [[ "$account_checked_at" =~ ^[0-9]+$ ]] || account_checked_at=0
    public_ip=$(echo "$cache" | jq -r '.publicIp // empty' 2>/dev/null)
    ip_checked_at=$(echo "$cache" | jq -r '.ipCheckedAt // 0' 2>/dev/null)
    [[ "$ip_checked_at" =~ ^[0-9]+$ ]] || ip_checked_at=0

    cache_dirty=0
    now_epoch=$(date +%s)
    account_age=$(( now_epoch - account_checked_at ))

    # Re-check periodically rather than "once ever" — a resumed session reuses
    # its session_id, so a permanent cache would keep showing a pre-switch
    # account forever after logging into a different one mid-session.
    if [[ -z "$account_plan" || -z "$account_email" || $account_age -ge $account_refresh_seconds ]]; then
        cache_dirty=1
        account_checked_at=$now_epoch
        auth_output=$(timeout 3 claude auth status --json 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            logged_in=$(echo "$auth_output" | jq -r '.loggedIn // false' 2>/dev/null)
            if [[ "$logged_in" == "true" ]]; then
                sub_type=$(echo "$auth_output" | jq -r '.subscriptionType // empty' 2>/dev/null)
                # Convert subscription type: replace _ with space and title-case
                if [[ -n "$sub_type" ]]; then
                    account_plan=$(echo "$sub_type" | sed 's/_/ /g' | sed 's/\b\(.\)/\u\1/g')
                fi
                account_email=$(echo "$auth_output" | jq -r '.email // empty' 2>/dev/null)
            else
                # Genuinely logged out — don't keep displaying a stale identity.
                account_plan=""
                account_email=""
            fi
        fi
        # else: the call failed/timed out — keep whatever plan/email was
        # already cached (last known-good, same behavior as the IP fetch
        # below) and retry after the next interval instead of every render.
    fi

    # Refresh public IP once the TTL elapses (or if we've never fetched it).
    # A failed fetch (e.g. DNS timeout) keeps the last known-good IP on screen
    # and still bumps the timestamp, so we retry after the interval instead of
    # re-stalling on a broken resolver every single render.
    ip_age=$(( now_epoch - ip_checked_at ))
    if [[ -z "$public_ip" || $ip_age -ge $ip_refresh_seconds ]]; then
        new_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null)
        [[ -n "$new_ip" ]] && public_ip="$new_ip"
        ip_checked_at=$now_epoch
        cache_dirty=1
    fi

    # Write cache if it was updated
    if [[ $cache_dirty -eq 1 ]]; then
        write_cache=$(jq -n \
            --arg plan "$account_plan" \
            --arg email "$account_email" \
            --arg ip "$public_ip" \
            --argjson checkedAt "$ip_checked_at" \
            --argjson acctCheckedAt "$account_checked_at" \
            '{plan: $plan, email: $email, publicIp: $ip, accountCheckedAt: $acctCheckedAt, ipCheckedAt: $checkedAt}')
        echo "$write_cache" > "$cache_file" 2>/dev/null
    fi

    # Prune cache files older than 1 day
    find "$cache_dir" -name "claude-statusline-account-*.json" -type f -mtime +1 ! -name "claude-statusline-account-$session_id.json" -delete 2>/dev/null
fi

# ---- Cache-efficiency indicator ----
# Price-weighted cache-savings ratio, pooled over the last N turns:
#   savings = ( (1 - W_READ)*R - (W_WRITE - 1)*W ) / (F + W + R)
# context_window.current_usage is a per-call snapshot, not cumulative, so state is persisted
# per-session in the temp dir (same pattern as the account-info cache above) and pooled here.
# jq does the floating-point math; bash has no native float arithmetic.
cache_w_read=0.10      # cache-read price / base-input price
cache_w_write=1.25     # cache-write price / base-input price (5-min TTL)
cache_n=5              # rolling window length, in turns
cache_green_at=0.70    # savings >= this -> green
cache_bar_cells=10

cost=$(echo "$json" | jq -r '.cost.total_cost_usd // empty')
cu_present=$(echo "$json" | jq -r 'if .context_window.current_usage == null then "0" else "1" end')
cu_f=$(echo "$json" | jq -r '.context_window.current_usage.input_tokens // 0')
cu_w=$(echo "$json" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cu_r=$(echo "$json" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')

cache_sid=$(echo "$session_id" | tr -cd 'a-zA-Z0-9_-')
[[ -z "$cache_sid" ]] && cache_sid="default"
cache_state_file="$cache_dir/claude-statusline-cache-$cache_sid.json"

cache_state=""
if [[ -f "$cache_state_file" ]]; then
    cache_state=$(cat "$cache_state_file" 2>/dev/null)
fi
if ! echo "$cache_state" | jq -e '.turns | type == "array"' >/dev/null 2>&1; then
    cache_state='{"last_cost":null,"turns":[]}'
fi

last_cost=$(echo "$cache_state" | jq -r '.last_cost // empty')

# Turn-boundary detection: a new billed API call changes total_cost_usd, and current_usage
# holds that same call's composition. Log once per call, not once per render.
if [[ "$cu_present" == "1" ]] && [[ -n "$cost" ]] && [[ "$cost" != "$last_cost" ]]; then
    cache_state=$(echo "$cache_state" | jq \
        --argjson f "$cu_f" --argjson w "$cu_w" --argjson r "$cu_r" \
        --argjson cost "$cost" --argjson n "$cache_n" \
        '.turns += [{"F":$f,"W":$w,"R":$r}] | .turns = (.turns[-$n:]) | .last_cost = $cost')
    cache_tmp_file="$cache_state_file.tmp.$$"
    echo "$cache_state" > "$cache_tmp_file" 2>/dev/null && mv -f "$cache_tmp_file" "$cache_state_file" 2>/dev/null

    # Prune cache-window files older than 1 day — gated to at most once per day via a
    # marker file. A turn boundary can hit multiple times per session, and a directory-wide
    # `find` over a busy temp dir (e.g. antivirus scanning each entry on Windows) can cost
    # multiple seconds; a per-write scan would make that tax recur on every single turn.
    cache_prune_marker="$cache_dir/.claude-statusline-cache-pruned-at"
    cache_prune_due=1
    if [[ -f "$cache_prune_marker" ]]; then
        cache_prune_mtime=$(stat -c %Y "$cache_prune_marker" 2>/dev/null || stat -f %m "$cache_prune_marker" 2>/dev/null || echo 0)
        [[ $(( $(date +%s) - cache_prune_mtime )) -lt 86400 ]] && cache_prune_due=0
    fi
    if [[ $cache_prune_due -eq 1 ]]; then
        touch "$cache_prune_marker" 2>/dev/null
        find "$cache_dir" -name "claude-statusline-cache-*.json" -type f -mtime +1 ! -name "claude-statusline-cache-$cache_sid.json" -delete 2>/dev/null
    fi
fi

# Pool F/W/R across retained turns and compute savings/zone/fill/pct in one jq call.
cache_computed=$(echo "$cache_state" | jq -r \
    --argjson wread "$cache_w_read" --argjson wwrite "$cache_w_write" \
    --argjson green "$cache_green_at" --argjson cells "$cache_bar_cells" '
    ( [.turns[].F] | add // 0 ) as $F |
    ( [.turns[].W] | add // 0 ) as $W |
    ( [.turns[].R] | add // 0 ) as $R |
    ($F + $W + $R) as $denom |
    if $denom == 0 then
        "0\t0\tnone"
    else
        (((1 - $wread) * $R - ($wwrite - 1) * $W) / $denom) as $s |
        (if $s < 0 then "red" elif $s < $green then "yellow" else "green" end) as $zone |
        ([$s, 0] | max) as $c0 |
        ([$c0, (1 - $wread)] | min) as $clamped |
        (($clamped / (1 - $wread) * $cells) | round) as $fill |
        (($s * 100) | round) as $pct |
        "\($pct)\t\($fill)\t\($zone)"
    end
')
IFS=$'\t' read -r cache_pct cache_fill cache_zone <<< "$cache_computed"

# ANSI color codes
cyan='\033[36m'
gray='\033[90m'
blue='\033[94m'
green='\033[32m'
yellow='\033[33m'
red='\033[31m'
magenta='\033[95m'
bold_white='\033[1;97m'
reset='\033[0m'

# ctx% stage framework (truecolor, thresholds from the Opus staging table)
ctx_stage1='\033[38;2;34;197;94m'    # 0-30%   Green    #22c55e  Optimal
ctx_stage2='\033[38;2;20;184;166m'   # 30-50%  Teal     #14b8a6  Healthy
ctx_stage3='\033[38;2;234;179;8m'    # 50-60%  Yellow   #eab308  Watch
ctx_stage4='\033[38;2;249;115;22m'   # 60-75%  Orange   #f97316  Handoff zone
ctx_stage5='\033[38;2;239;68;68m'    # 75-83%  Red      #ef4444  Danger
ctx_stage6='\033[38;2;153;27;27m'    # 83%+    Dark red #991b1b  Critical/lossy

line=""

# Model
if [[ -n "$model" ]]; then
    line="${bold_white}${model}${reset}"
fi

# Effort with color map
if [[ -n "$effort" ]]; then
    case "$effort" in
        low)    effort_color="$blue" ;;
        medium) effort_color="$green" ;;
        high)   effort_color="$yellow" ;;
        xhigh)  effort_color="$red" ;;
        max)    effort_color="$magenta" ;;
        *)      effort_color="$yellow" ;;
    esac
    line="$line ${effort_color}[${effort}]${reset}"
fi

# Context usage with 6-stage color
if [[ -n "$used" && "$used" != "null" ]]; then
    used_int=$(printf "%.0f" "$used")
    if [[ $used_int -ge 83 ]]; then
        ctx_color="$ctx_stage6"
    elif [[ $used_int -ge 75 ]]; then
        ctx_color="$ctx_stage5"
    elif [[ $used_int -ge 60 ]]; then
        ctx_color="$ctx_stage4"
    elif [[ $used_int -ge 50 ]]; then
        ctx_color="$ctx_stage3"
    elif [[ $used_int -ge 30 ]]; then
        ctx_color="$ctx_stage2"
    else
        ctx_color="$ctx_stage1"
    fi
    line="$line  ${ctx_color}ctx:${used_int}%${reset}"
fi

# Account plan and email
if [[ -n "$account_plan" || -n "$account_email" ]]; then
    line="$line  ${green}${account_plan}${reset} ${gray}·${reset} ${cyan}${account_email}${reset}"
fi

# Hostname / LAN IP (WAN IP)
hostname_val="${HOSTNAME:-$(hostname 2>/dev/null)}"
if [[ -n "$hostname_val" ]]; then
    line="$line  ${cyan}${hostname_val}${reset}"
    if [[ -n "$lan_ip" ]]; then
        line="$line ${gray}/${reset} ${cyan}${lan_ip}${reset}"
    fi
    if [[ -n "$public_ip" ]]; then
        line="$line ${gray}(${reset}${cyan}${public_ip}${reset}${gray})${reset}"
    fi
fi

# Line 1 output
printf "%b\n" "$line"

# Line 2: 5-hour rate limit bar
if [[ -n "$rate_used" && "$rate_used" != "null" && -n "$rate_resets" && "$rate_resets" != "null" ]]; then
    pct=$(printf "%.0f" "$rate_used")

    bar_width=40
    filled=$(( (pct * bar_width) / 100 ))
    if [[ $filled -gt $bar_width ]]; then filled=$bar_width; fi
    if [[ $filled -lt 0 ]]; then filled=0; fi

    # Build the bar
    bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<bar_width; i++)); do bar+="░"; done

    # Color the bar with the same 6-stage gradient as ctx% (warmer as the session fills)
    if [[ $pct -ge 83 ]]; then
        bar_color="$ctx_stage6"
    elif [[ $pct -ge 75 ]]; then
        bar_color="$ctx_stage5"
    elif [[ $pct -ge 60 ]]; then
        bar_color="$ctx_stage4"
    elif [[ $pct -ge 50 ]]; then
        bar_color="$ctx_stage3"
    elif [[ $pct -ge 30 ]]; then
        bar_color="$ctx_stage2"
    else
        bar_color="$ctx_stage1"
    fi

    # Calculate time remaining
    now_epoch=$(date +%s)
    remaining=$((rate_resets - now_epoch))
    stale=0
    if [[ $remaining -le 0 ]]; then
        stale=1
        remaining=0
    fi

    hours=$((remaining / 3600))
    minutes=$(((remaining % 3600) / 60))

    if [[ $hours -gt 0 ]]; then
        reset_str="${hours}h ${minutes}m"
    else
        reset_str="${minutes}m"
    fi

    # resets_at has passed, but Claude Code only refreshes rate_limits on the
    # next API call, so pct above may be a stale snapshot too — flag it rather
    # than show a countdown frozen at 0m.
    if [[ $stale -eq 1 ]]; then
        session_line="${gray}Session ${reset}${bar_color}${bar}${reset} ${pct}% used ${gray}· awaiting refresh${reset}"
    else
        session_line="${gray}Session ${reset}${bar_color}${bar}${reset} ${pct}% used ${gray}·${reset} resets in ${reset_str}"
    fi

    # Cache-efficiency segment, appended after the Session bar on the same line.
    if [[ "$cache_zone" == "none" ]]; then
        cache_segment="  ${gray}·${reset}  ${gray}cache ······ warming up${reset}"
    else
        case "$cache_zone" in
            red)    cache_color="$red" ;;
            yellow) cache_color="$yellow" ;;
            green)  cache_color="$green" ;;
        esac

        cache_bar=""
        for ((i=0; i<cache_fill; i++)); do cache_bar+="▓"; done
        for ((i=cache_fill; i<cache_bar_cells; i++)); do cache_bar+="░"; done

        cache_warn=""
        [[ "$cache_zone" == "red" ]] && cache_warn=" ${red}⚠${reset}"

        cache_cost_str=""
        if [[ -n "$cost" ]]; then
            cache_cost_fmt=$(printf '%.2f' "$cost")
            cache_cost_str="  ${gray}·${reset}  \$${cache_cost_fmt}"
        fi

        cache_segment="  ${gray}·${reset}  ${gray}cache${reset} ${cache_color}${cache_bar} ${cache_pct}%${reset}${cache_warn}${cache_cost_str}"
    fi
    session_line="${session_line}${cache_segment}"

    printf "%b" "$session_line"
fi
