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

# Cache directory and file
cache_dir="${TMPDIR:-/tmp}"
cache_file="$cache_dir/claude-statusline-account-$session_id.json"

# Only fetch identity-related data if the flag is explicitly enabled
if [[ "$CLAUDE_STATUSLINE_SHOW_IDENTITY" == "1" ]] && [[ -n "$session_id" ]]; then
    cache=""
    if [[ -f "$cache_file" ]]; then
        cache=$(cat "$cache_file" 2>/dev/null)
    fi

    account_plan=$(echo "$cache" | jq -r '.plan // empty' 2>/dev/null)
    account_email=$(echo "$cache" | jq -r '.email // empty' 2>/dev/null)
    public_ip=$(echo "$cache" | jq -r '.publicIp // empty' 2>/dev/null)
    account_checked=$(echo "$cache" | jq -r '.accountChecked // false' 2>/dev/null)
    ip_checked=$(echo "$cache" | jq -r '.ipChecked // false' 2>/dev/null)

    cache_dirty=0

    # Fetch account info if not cached
    if [[ "$account_checked" != "true" ]] && [[ -z "$account_plan" || -z "$account_email" ]]; then
        cache_dirty=1
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
            fi
        fi
    fi

    # Fetch public IP if not cached
    if [[ "$ip_checked" != "true" ]] && [[ -z "$public_ip" ]]; then
        cache_dirty=1
        public_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null)
    fi

    # Write cache if it was updated
    if [[ $cache_dirty -eq 1 ]]; then
        write_cache=$(jq -n \
            --arg plan "$account_plan" \
            --arg email "$account_email" \
            --arg ip "$public_ip" \
            '{plan: $plan, email: $email, publicIp: $ip, accountChecked: true, ipChecked: true}')
        echo "$write_cache" > "$cache_file" 2>/dev/null
    fi

    # Prune cache files older than 1 day
    find "$cache_dir" -name "claude-statusline-account-*.json" -type f -mtime +1 ! -name "claude-statusline-account-$session_id.json" -delete 2>/dev/null
fi

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

# Hostname
hostname_val="${HOSTNAME:-$(hostname 2>/dev/null)}"
if [[ -n "$hostname_val" ]]; then
    if [[ -n "$public_ip" ]]; then
        line="$line  ${cyan}${hostname_val}${reset} ${gray}(${reset}${cyan}${public_ip}${reset}${gray})${reset}"
    else
        line="$line  ${cyan}${hostname_val}${reset}"
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
    if [[ $remaining -lt 0 ]]; then remaining=0; fi

    hours=$((remaining / 3600))
    minutes=$(((remaining % 3600) / 60))

    if [[ $hours -gt 0 ]]; then
        reset_str="${hours}h ${minutes}m"
    else
        reset_str="${minutes}m"
    fi

    session_line="${gray}Session ${reset}${bar_color}${bar}${reset} ${pct}% used ${gray}·${reset} resets in ${reset_str}"
    printf "%b" "$session_line"
fi
