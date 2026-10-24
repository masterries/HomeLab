#!/usr/bin/env bash
# setup-zsh.sh - installs zsh with good history search and makes it the login shell.
#
# WHERE AND HOW IT RUNS
#   On the Ubuntu lab VMs (ansible-control, matrix, keycloak), as root, through Vagrant's shell
#   provisioner "zsh" (vagrant/Vagrantfile passes "vagrant ansible"). Works on any Ubuntu VM;
#   can also be run by hand:
#     setup-zsh.sh USER...        e.g. setup-zsh.sh vagrant ansible
#   It runs after bootstrap-ansible-user.sh, because the users must already exist.
#
# WHY
#   Not part of the network design, but you spend a lot of time in these shells. It also
#   shows a common configuration-management pattern: a system-wide file that automation owns
#   and overwrites (/etc/zsh/zshrc.lab), and a per-user file that automation creates only
#   once and then leaves to the user (~/.zshrc).
#
# History search:
#   Ctrl+R             fuzzy search through the whole history (fzf)
#   Up/Down arrow      search the history for lines starting with what you have typed
#   Right arrow        accept the grey suggestion from the history
# The history is shared immediately between all open shells.
#
# IDEMPOTENT: safe to run any number of times. /etc/zsh/zshrc.lab is rewritten on every run;
# ~/.zshrc is created or extended only if it does not contain the line
# 'source /etc/zsh/zshrc.lab' yet, so your own settings there are kept. The login shell is
# only changed if it is not zsh already.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 USER..." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq zsh fzf zsh-autosuggestions zsh-syntax-highlighting >/dev/null

# Shared setup. The heredoc delimiter is quoted ('EOF'), so bash writes the text literally
# without expanding $ or ${...}; those are meant for zsh.
cat > /etc/zsh/zshrc.lab <<'EOF'
# Shared zsh setup of the lab VMs. Managed by setup-zsh.sh and overwritten at the next
# provisioning; put your own settings in ~/.zshrc.

# History: large, without duplicates, shared immediately between all shells.
# Commands that start with a space are not saved in the history (useful for secrets).
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt EXTENDED_HISTORY SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY

# Emacs-style line editing (Ctrl+A, Ctrl+E, ...), like bash
bindkey -e

# Up/Down arrow: search the history for lines starting with what you have typed.
# Bind both variants: depending on the terminal mode the key sends ^[[A or ^[OA.
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search

# Tab completion; "menu select" lets you pick a candidate with the arrow keys.
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select

# fzf: Ctrl+R history, Ctrl+T files, Alt+C change directory
source /usr/share/doc/fzf/examples/key-bindings.zsh
source /usr/share/doc/fzf/examples/completion.zsh

# Grey suggestion from the history while typing (accept with the Right arrow)
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

alias ll='ls -l'

# Prompt: user@host:path (git branch)
# No blue: unreadable on the blue background of Windows PowerShell.
autoload -Uz add-zsh-hook vcs_info
add-zsh-hook precmd vcs_info
zstyle ':vcs_info:git:*' formats ' (%b)'
setopt PROMPT_SUBST
PROMPT='%F{green}%n@%m%f:%F{cyan}%~%f%F{yellow}${vcs_info_msg_0_}%f%# '

# Must be loaded last (it hooks into the line editor set up above).
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
# The two default styles that are blue (globs like *.yml, history expansions like !!)
ZSH_HIGHLIGHT_STYLES[globbing]='fg=magenta'
ZSH_HIGHLIGHT_STYLES[history-expansion]='fg=magenta'
EOF
chmod 0644 /etc/zsh/zshrc.lab

# Starting content of a user's ~/.zshrc. The loop below looks for the exact line
# 'source /etc/zsh/zshrc.lab' to tell whether a .zshrc already has the lab setup, so that
# line must stay unchanged.
zshrc_template='# Shared lab setup (history search etc.), see /etc/zsh/zshrc.lab
source /etc/zsh/zshrc.lab

# Your own settings below this line'

# New users get the setup automatically: useradd --create-home copies /etc/skel into the new
# home directory.
if [[ ! -f /etc/skel/.zshrc ]]; then
  printf '%s\n' "$zshrc_template" > /etc/skel/.zshrc
fi

zsh_path="$(command -v zsh)"
for user in "$@"; do
  if ! id "$user" >/dev/null 2>&1; then
    echo "ERROR: User $user does not exist." >&2
    exit 1
  fi
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  zshrc="$home_dir/.zshrc"
  if [[ ! -f "$zshrc" ]]; then
    printf '%s\n' "$zshrc_template" > "$zshrc"
    chown "$user:$(id -gn "$user")" "$zshrc"
  elif ! grep -qF 'source /etc/zsh/zshrc.lab' "$zshrc"; then
    # Keep the existing .zshrc, only put the lab setup in front of it.
    zshrc_tmp="$(mktemp)"
    { printf '%s\n\n' "$zshrc_template"; cat "$zshrc"; } > "$zshrc_tmp"
    install -m 0644 -o "$user" -g "$(id -gn "$user")" "$zshrc_tmp" "$zshrc"
    rm -f "$zshrc_tmp"
  fi
  # Field 7 of the passwd entry is the login shell.
  if [[ "$(getent passwd "$user" | cut -d: -f7)" != "$zsh_path" ]]; then
    usermod -s "$zsh_path" "$user"
  fi
  echo "zsh set up for $user"
done
