# Claudebox command auditing
# This script is sourced by bash to log all commands
#
# Log format: timestamp | exit_code | command
# Log location: /var/log/claudebox/commands.log
#
# The log file should be set to append-only (chattr +a) on the host
# to prevent tampering. See SECURE_CLAUDE_CODE.md Design 8.

CLAUDEBOX_LOG="/var/log/claudebox/commands.log"

# Only enable logging if the log directory exists and is writable
if [[ -d "$(dirname "$CLAUDEBOX_LOG")" ]] && [[ -w "$(dirname "$CLAUDEBOX_LOG")" ]]; then
    export PROMPT_COMMAND='
        _exit_code=$?
        _cmd=$(history 1 | sed "s/^[ ]*[0-9]*[ ]*//")
        if [[ -n "$_cmd" ]]; then
            echo "$(date -Iseconds) | $_exit_code | $_cmd" >> '"$CLAUDEBOX_LOG"' 2>/dev/null
        fi
    '
fi
