#!/bin/bash
# Install claude-statusline on Linux/macOS
# Copies statusline-command.sh to ~/.claude, patches settings.json with absolute paths.
# Backs up prior settings.json to settings.json.pre-statusline.

set -e

# Resolve home directory
home_dir="${HOME:?HOME not set}"
claude_dir="$home_dir/.claude"

# Check for required dependencies
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required but not installed"
    echo "Install it via: apt install jq (Debian/Ubuntu), brew install jq (macOS), etc."
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "ERROR: curl is required but not installed"
    exit 1
fi

# Create .claude directory if missing
mkdir -p "$claude_dir"
if [[ ! -d "$claude_dir" ]]; then
    echo "ERROR: Could not create $claude_dir"
    exit 1
fi

# Determine script directory
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Copy statusline-command.sh
source_script="$script_dir/statusline-command.sh"
dest_script="$claude_dir/statusline-command.sh"

if [[ ! -f "$source_script" ]]; then
    echo "ERROR: statusline-command.sh not found in $script_dir"
    exit 1
fi

cp "$source_script" "$dest_script"
chmod +x "$dest_script"
echo "Copied statusline-command.sh to $dest_script"

# Resolve settings.json
settings_json="$claude_dir/settings.json"
backup_json="$claude_dir/settings.json.pre-statusline"

# Read existing settings or create empty structure
if [[ -f "$settings_json" ]]; then
    # Back up existing if this is the first install
    if [[ ! -f "$backup_json" ]]; then
        cp "$settings_json" "$backup_json"
        echo "Backed up prior settings.json to settings.json.pre-statusline"
    fi
    # Parse and update existing JSON
    settings=$(cat "$settings_json")
else
    settings="{}"
fi

# Update statusLine block with absolute path using jq
settings=$(echo "$settings" | jq \
    --arg cmd "bash $dest_script" \
    '.statusLine = {
        type: "command",
        command: $cmd,
        refreshInterval: 30
    }')

# Write updated settings.json
echo "$settings" | jq '.' > "$settings_json"
echo "Patched settings.json with statusLine command at $dest_script"

echo ""
echo "Installation complete!"
echo ""
echo "To show email + public IP on trusted machines, set:"
echo "  export CLAUDE_STATUSLINE_SHOW_IDENTITY=1"
echo "Or add to ~/.bashrc or ~/.zshrc for persistence:"
echo "  echo 'export CLAUDE_STATUSLINE_SHOW_IDENTITY=1' >> ~/.bashrc"
echo ""
echo "Otherwise, only model, effort, context%, and hostname are shown."
