# bash completion for ssm-connect
# Installed to a bash-completion dir (e.g. /etc/bash_completion.d or
# $(brew --prefix)/etc/bash_completion.d) by install.sh.

_ssm_connect() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    # Fallback when bash-completion's _init_completion isn't available
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cword=$COMP_CWORD
    words=("${COMP_WORDS[@]}")
  }

  local alias_file="${SSM_CONNECT_ALIAS_FILE:-$HOME/.ssm-connect/aliases}"

  local opts="--add-alias --remove-alias --list-aliases --set-group \
--unset-group --scp --check-update --update --install-bash-completion \
--install-zsh-completion --help --version --uninstall --whats-new"

  # Helpers that read the alias file (one entry per line: "alias id [group]")
  _ssm_aliases() {
    [[ -r "$alias_file" ]] && awk '{print $1}' "$alias_file"
  }
  _ssm_groups() {
    [[ -r "$alias_file" ]] && awk 'NF>=3{print $3}' "$alias_file" | sort -u
  }

  # First word: an option, an alias, or a group
  if [[ $cword -eq 1 ]]; then
    if [[ "$cur" == -* ]]; then
      COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "$(_ssm_aliases; _ssm_groups)" -- "$cur") )
    fi
    return 0
  fi

  # Context-sensitive completion based on the chosen subcommand
  case "${words[1]}" in
    --remove-alias|-r|--set-group|--unset-group)
      # First argument to these is always an existing alias
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$(_ssm_aliases)" -- "$cur") )
      elif [[ $cword -eq 3 && "${words[1]}" == "--set-group" ]]; then
        COMPREPLY=( $(compgen -W "$(_ssm_groups)" -- "$cur") )
      fi
      return 0
      ;;
    --add-alias|-a)
      # -a <alias> <instance-id> [group] — complete group on 4th arg
      if [[ $cword -eq 4 ]]; then
        COMPREPLY=( $(compgen -W "$(_ssm_groups)" -- "$cur") )
      fi
      return 0
      ;;
    --scp)
      # alias:path remote, or a local file/dir
      if [[ "$cur" != *:* ]]; then
        COMPREPLY=( $(compgen -W "$(_ssm_aliases | sed 's/$/:/')" -- "$cur") )
        compopt -o nospace 2>/dev/null
        # Also offer local files
        COMPREPLY+=( $(compgen -f -- "$cur") )
      fi
      return 0
      ;;
  esac

  return 0
}

complete -F _ssm_connect ssm-connect
