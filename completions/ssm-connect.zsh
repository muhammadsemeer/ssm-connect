#compdef ssm-connect
# zsh completion for ssm-connect.
#
# Installed as `_ssm-connect` into a zsh site-functions directory (one that is
# on $fpath) by install.sh and `ssm-connect --install-zsh-completion`. Mirrors
# the bash completion: completes flags, alias names, group names, and `alias:`
# targets for --scp, all driven by ~/.ssm-connect/aliases.

local alias_file="${SSM_CONNECT_ALIAS_FILE:-$HOME/.ssm-connect/aliases}"
local -a aliases groups options

# Read the alias file (one entry per line: "alias id [group]").
aliases=(${(f)"$([[ -r "$alias_file" ]] && awk '{print $1}' "$alias_file")"})
groups=(${(f)"$([[ -r "$alias_file" ]] && awk 'NF>=3 {print $3}' "$alias_file" | sort -u)"})

options=(
  '--add-alias:Add or update an alias'
  '-a:Add or update an alias'
  '--remove-alias:Remove an alias'
  '-r:Remove an alias'
  '--list-aliases:List all aliases'
  '-l:List all aliases'
  '--set-group:Set or change an alias group'
  '--unset-group:Clear an alias group'
  '--scp:Copy files via SSM/S3'
  '--check-update:Check for updates'
  '--update:Update to the latest version'
  '--install-bash-completion:Install bash completion'
  '--install-zsh-completion:Install zsh completion'
  '--whats-new:Show release notes'
  '--version:Show installed version'
  '--uninstall:Uninstall ssm-connect'
  '--help:Show help'
  '-h:Show help'
)

# First word: an option, an alias, or a group.
if (( CURRENT == 2 )); then
  if [[ ${words[CURRENT]} == -* ]]; then
    _describe -t options 'option' options
  else
    _describe -t aliases 'alias' aliases
    _describe -t groups 'group' groups
  fi
  return
fi

# Context-sensitive completion based on the chosen subcommand.
case ${words[2]} in
  --remove-alias|-r|--set-group|--unset-group)
    # First argument to these is an existing alias.
    if (( CURRENT == 3 )); then
      _describe -t aliases 'alias' aliases
    elif (( CURRENT == 4 )) && [[ ${words[2]} == --set-group ]]; then
      _describe -t groups 'group' groups
    fi
    ;;
  --add-alias|-a)
    # -a <alias> <instance-id> [group] — complete the group as the 3rd argument.
    (( CURRENT == 5 )) && _describe -t groups 'group' groups
    ;;
  --scp)
    # alias:path remote target, or a local file/dir.
    if [[ ${words[CURRENT]} != *:* ]]; then
      compadd -S ':' -- $aliases   # alias: targets, no trailing space
      _files                       # or a local path
    fi
    ;;
esac
