#!/usr/bin/env bash
# =============================================================================
# agent-box.sh — one-shot agentic toolbox installer for a fresh Ubuntu box
# =============================================================================
# Installs a curated, deliberately small set of CLI tools that coding agents
# (Hermes, pi, or anything else that drives a shell) reach for constantly,
# plus a Python virtual environment of wheel-only agent packages.
#
# Stages, each one asking before it acts:
#   Stage 1  Ubuntu packages    required. A failure exits nonzero.
#   Stage 2  Python packages    required. A failure exits nonzero.
#   Stage 3  Shell conveniences optional. Failure only warns.
#   Stage 4  Command aliases    optional. Failure only warns.
#   Stage 5  Verification       never fails the run.
#
# Design rules:
#   - Ubuntu and Debian family only. No dnf, pacman, zypper, or apk branches.
#     The script exits nonzero on anything else rather than guessing.
#   - Apt names are resolved, not assumed. Ubuntu renames packages often
#     (libasound2 -> libasound2t64 since 24.04), and a package with no install
#     candidate is skipped with one compact warning, never a fatal error.
#   - Idempotent. Re-running installs nothing and changes nothing.
#   - No compiler-heavy Python packages. Every default Python package ships a
#     wheel for the running interpreter, so Stage 2 stays fast.
#   - Nothing outside the package manager, the venv, and ~/.local/bin is
#     touched. No harness installer, no shell rc edits unless Stage 3 is
#     accepted.
#
# Why each group exists, in one line:
#   base       fetch, unpack, patch, compile, edit, read manuals
#   python     the interpreter, the venv module, and headers
#   search     fast code search, file find, fuzzy jump, colored cat
#   inspect    process, port, disk, and system state at a glance
#   git        git, LFS, delta pager, GitHub CLI
#   data       JSON, YAML, CSV, and SQL from the command line
#   net        sockets, DNS, ping, traceroute, TLS
#   dev        lint, format, hooks, and env-var tooling
#   docs       read PDF text out of a terminal
#   media      ffmpeg, ImageMagick, audio and GL introspection
#   x11        window control, screen capture, clipboard, notifications
#   secrets    keyring, libsecret, and age for encrypted handoff
#
# Usage examples:
#   ./agent-box.sh                    # guided, asks before each group
#   ./agent-box.sh --all              # accept every optional step
#   ./agent-box.sh --dry-run          # print the plan, change nothing
#   ./agent-box.sh --minimal          # base, python, search, git, dev only
#   ./agent-box.sh --py-science       # add numpy and pandas to the venv
#
# Language: American English. No API endpoint and no API key are used here.
# =============================================================================
set -uo pipefail

# ---- Configuration, every value overridable from the environment ------------
PY_VENV="${PY_VENV:-$HOME/.agentbox-venv}"
PY_PACKAGES="${PY_PACKAGES:-}"
PY_PACKAGES_MINIMAL="pip setuptools wheel packaging requests httpx rich typer pydantic pydantic-settings pytest ruff psutil pypdf python-dotenv"
PY_PACKAGES_SCIENCE="numpy pandas"
LOG_FILE="${LOG_FILE:-$HOME/agent-box.log}"
BINDIR="${BINDIR:-$HOME/.local/bin}"
# Empty means interactive. Set to yes or no to answer every prompt the same way.
WIZARD_ASSUME="${WIZARD_ASSUME:-}"

usage() {
  cat <<'USAGE'
Usage: agent-box.sh [options]

Stages, each one asking before it acts:
  Stage 1  Ubuntu packages     required, nonzero exit on failure
  Stage 2  Python packages     required, nonzero exit on failure
  Stage 3  Shell conveniences  optional
  Stage 4  Command aliases     optional, fdfind -> fd and batcat -> bat
  Stage 5  Verification        never fails the run

Options:
  --minimal          Stage 1 installs base, python, search, git, dev, x11,
                     secrets only, and declines every optional group
  --all              Synonym for --auto: accept every prompt and optional step
  --no-packages      Skip Stage 1 entirely
  --no-optional      Stage 1 installs the required groups, skips every
                     optional group without asking
  --no-python        Skip Stage 2 entirely
  --no-shell         Skip Stage 3 (no shell rc edit)
  --no-aliases       Skip Stage 4
  --py-minimal       Stage 2 installs a small, high-value Python subset
  --py-science       Stage 2 also installs numpy and pandas
  --py-packages LIST Replace the whole Stage 2 Python package list
  --py-venv DIR      Set the Stage 2 virtual environment directory
  --dry-run          Print every action, change nothing on disk
  --auto, --yes, -y  Assume yes at every prompt
  --assume VALUE     Answer every prompt with VALUE, yes or no
  --log FILE         Set the log file
  -h, --help         Show this help
USAGE
}

# ---- Output -----------------------------------------------------------------
# These functions must exist before the option loop runs: the unknown-option
# branch calls err.
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'
  C=$'\033[0;36m'; M=$'\033[0;35m'; BD=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; C=""; M=""; BD=""; N=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s->%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%sOK%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%sX%s %s\n' "$R" "$N" "$*" >&2; }

# ---- Options ----------------------------------------------------------------
MINIMAL=false
ALL_OPTIONAL=false
NO_PACKAGES=false
NO_OPTIONAL=false
NO_PYTHON=false
NO_SHELL=false
NO_ALIASES=false
PY_MINIMAL=false
PY_SCIENCE=false
DRY_RUN=false
AUTO=false

while [ $# -gt 0 ]; do
  case "$1" in
    --minimal)         MINIMAL=true; shift ;;
    --all)             ALL_OPTIONAL=true; shift ;;
    --no-packages)     NO_PACKAGES=true; shift ;;
    --no-optional)     NO_OPTIONAL=true; shift ;;
    --no-python)       NO_PYTHON=true; shift ;;
    --no-shell)        NO_SHELL=true; shift ;;
    --no-aliases)      NO_ALIASES=true; shift ;;
    --py-minimal)      PY_MINIMAL=true; shift ;;
    --py-science)      PY_SCIENCE=true; shift ;;
    --py-packages)     PY_PACKAGES="$2"; shift 2 ;;
    --py-venv)         PY_VENV="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --auto|--yes|-y)   AUTO=true; shift ;;
    --assume)          WIZARD_ASSUME="${2:-}"; shift 2 ;;
    --log)             LOG_FILE="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) err "Unknown option: $1 (use --help)"; exit 2 ;;
  esac
done

if [ "$AUTO" = true ] && [ -z "$WIZARD_ASSUME" ]; then
  WIZARD_ASSUME="yes"
fi
if [ "$ALL_OPTIONAL" = true ] && [ -z "$WIZARD_ASSUME" ]; then
  WIZARD_ASSUME="yes"
fi

# The default Python list. Every entry ships a wheel, so pip never needs a
# compiler and Stage 2 finishes in seconds rather than minutes.
if [ -z "$PY_PACKAGES" ]; then
  PY_PACKAGES="pip setuptools wheel packaging
requests httpx httpie
pydantic pydantic-settings typer rich prompt-toolkit textual jinja2 pyyaml tomli-w jsonschema python-dotenv tenacity
orjson tqdm python-dateutil rapidfuzz markdown
psutil watchdog
pypdf openpyxl Pillow python-docx beautifulsoup4
pytest ruff mypy ipython ipdb uv"
fi
[ "$PY_MINIMAL" = true ] && PY_PACKAGES="$PY_PACKAGES_MINIMAL"
[ "$PY_SCIENCE" = true ] && PY_PACKAGES="$PY_PACKAGES $PY_PACKAGES_SCIENCE"

# ---- Wizard input -----------------------------------------------------------
# Every stage calls this before it acts. The prompt always prints first. A
# closed stdin never stops the run: it falls back to the stated default.
ask_yes_no() {
  local prompt="$1" default="${2:-n}" reply=""
  if [ -n "$WIZARD_ASSUME" ]; then
    say "$prompt [non-interactive answer: $WIZARD_ASSUME]"
    case "$WIZARD_ASSUME" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
  if [ ! -t 0 ]; then
    say "$prompt [no terminal: default $default]"
    case "$default" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
  printf '%s ' "$prompt"
  read -r reply || reply=""
  [ -z "$reply" ] && reply="$default"
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- sudo / root ------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    err "Not root and no sudo found. Stage 1 cannot install system packages."
    exit 1
  fi
fi

# ---- Apt plumbing -----------------------------------------------------------
apt_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  case "$st" in *"install ok installed"*) return 0 ;; *) return 1 ;; esac
}

# Can this package actually be installed right now?
# "apt-cache show" is not enough: it still succeeds for a stale record whose
# candidate is (none), which is what Ubuntu 26.04 does with the pre-t64
# libasound2. "apt-cache policy" exposes the candidate, so probe that.
apt_available() {
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

# Resolve one requested package name to a name this distro can actually
# install. Prints the resolved name and returns 0, or returns 1 if there is
# nothing usable. Handles the 64-bit time_t rename that Ubuntu 24.04 and
# later did: libasound2 -> libasound2t64, libatk1.0-0 -> libatk1.0-0t64. Both
# spellings are tried in both directions, because some packages gained the
# suffix with a hyphen and some without.
apt_resolve() {
  local p="$1" sib
  if apt_installed "$p" || apt_available "$p"; then
    printf '%s' "$p"
    return 0
  fi
  local -a siblings=("${p}-t64" "${p}t64")
  case "$p" in
    *-t64) siblings+=("${p%-t64}") ;;
    *t64)  siblings+=("${p%t64}") ;;
  esac
  for sib in "${siblings[@]}"; do
    [ "$sib" = "$p" ] && continue
    if apt_available "$sib"; then
      printf '%s' "$sib"
      return 0
    fi
  done
  return 1
}

APT_UPDATED=false
apt_update_once() {
  [ "$APT_UPDATED" = true ] && return 0
  [ "$DRY_RUN" = true ] && return 0
  info "apt-get update"
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get update -qq || warn "apt-get update reported errors (continuing)"
  APT_UPDATED=true
}

# ---- Package groups ---------------------------------------------------------
# One line per group. Names that a given Ubuntu release renamed are listed
# once in their old spelling; apt_resolve finds the current one.
group_pkgs() {
  case "$1" in
    base)    echo "ca-certificates curl wget gnupg openssh-client git-lfs git-delta \
build-essential pkg-config cmake meson make unzip zip xz-utils tar rsync file patch bzip2 \
jq less nano vim-tiny tmux screen man-db manpages locales tzdata lsb-release starship zoxide" ;;
    python)  echo "python3 python3-venv python3-dev python3-pip python3-setuptools libffi-dev" ;;
    search)  echo "ripgrep ripgrep-all fd-find fzf bat silversearcher-ag tree eza lsd" ;;
    inspect) echo "htop btop procs ncdu lsof psmisc procps iproute2 iputils-ping net-tools" ;;
    git)     echo "git git-lfs git-delta gh" ;;
    data)    echo "jq yq miller csvtool sqlite3" ;;
    net)     echo "netcat-openbsd socat bind9-dnsutils iputils-ping traceroute mtr openssl" ;;
    dev)     echo "shellcheck shfmt pre-commit direnv patch" ;;
    docs)    echo "poppler-utils qpdf" ;;
    media)   echo "ffmpeg imagemagick alsa-utils" ;;
    x11)     echo "xdotool wmctrl x11-utils x11-xserver-utils xauth xclip xsel scrot \
dbus-x11 at-spi2-core libnotify-bin xdg-utils \
fonts-liberation fonts-dejavu-core fonts-noto-color-emoji" ;;
    secrets) echo "gnome-keyring libsecret-1-0 libsecret-tools age pass" ;;
    # ------------------------- optional groups ---------------------------
    headless)     echo "xvfb x11vnc openbox fluxbox xterm" ;;
    desktop-build) echo "libgtk-3-0 libnotify4 libxtst6 rpm fakeroot dpkg-dev" ;;
    containers)   echo "podman podman-docker uidmap slirp4netns fuse-overlayfs" ;;
    databases)    echo "redis-tools postgresql-client default-mysql-client" ;;
    net-scan)     echo "nmap whois" ;;
    shell-history) echo "atuin" ;;
    docs-full)    echo "pandoc tesseract-ocr" ;;
    monitor)      echo "glances" ;;
    *) echo "" ;;
  esac
}

# One line of prose per group, shown before it is installed. Group names carry
# hyphens, which bash cannot put in a variable name, so this is a case table.
group_desc() {
  case "$1" in
    base)           echo "fetch, unpack, patch, compile, edit" ;;
    python)         echo "interpreter, venv, headers" ;;
    search)         echo "rg, rga, fd, fzf, bat, ag, tree, eza" ;;
    inspect)        echo "htop, btop, procs, ncdu, lsof, iproute2" ;;
    git)            echo "git, lfs, delta, gh" ;;
    data)           echo "jq, yq, mlr, csvtool, sqlite3" ;;
    net)            echo "nc, socat, dig, ping, traceroute, mtr" ;;
    dev)            echo "shellcheck, shfmt, pre-commit, direnv" ;;
    docs)           echo "pdftotext, qpdf" ;;
    media)          echo "ffmpeg, imagemagick, alsa-utils" ;;
    x11)            echo "xdotool, wmctrl, screen capture, clipboard" ;;
    secrets)        echo "gnome-keyring, libsecret, age" ;;
    headless)       echo "Xvfb, x11vnc, openbox, fluxbox, xterm" ;;
    desktop-build)  echo "gtk3, rpm, fakeroot, dpkg-dev" ;;
    containers)     echo "podman, uidmap, slirp4netns" ;;
    databases)      echo "redis, postgres, mysql clients" ;;
    net-scan)       echo "nmap, whois" ;;
    shell-history)  echo "atuin shell history" ;;
    docs-full)      echo "pandoc, tesseract-ocr" ;;
    monitor)        echo "glances" ;;
    *)              echo "" ;;
  esac
}

# ---- Install one package group ---------------------------------------------
# Returns 0 when the group is already satisfied or installs cleanly.
# Returns 1 only when something is genuinely still missing at the end.
install_group() {
  local name="$1"
  local -a want=()
  read -r -a want <<<"$(group_pkgs "$name")"
  [ "${#want[@]}" -eq 0 ] && return 0

  # Refresh the indexes first. The candidate probe below is only as good as the
  # package lists, and a stale list reports a renamed package as uninstallable.
  apt_update_once

  local -a todo=() skipped=()
  local seen="" p r
  for p in "${want[@]}"; do
    if ! r="$(apt_resolve "$p")"; then
      skipped+=("$p")
      continue
    fi
    case " $seen " in *" $r "*) continue ;; esac
    seen="$seen $r"
    apt_installed "$r" && continue
    todo+=("$r")
  done
  if [ "${#skipped[@]}" -gt 0 ]; then
    warn "[$name] no install candidate, skipped: ${skipped[*]}"
  fi
  if [ "${#todo[@]}" -eq 0 ]; then
    ok "[$name] already satisfied"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    say "  ${BD}[$name]${N} would apt-get install: ${todo[*]}"
    return 0
  fi

  info "[$name] installing ${#todo[@]} package(s)"
  if $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
       apt-get install -y -qq --no-install-recommends "${todo[@]}"; then
    ok "[$name] installed"
    return 0
  fi
  warn "[$name] retrying without --no-install-recommends"
  if $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
       apt-get install -y -qq "${todo[@]}"; then
    ok "[$name] installed"
    return 0
  fi
  # Last resort: one package at a time, so a single unbuildable or conflicting
  # name cannot take the whole group down with it.
  warn "[$name] falling back to one package at a time"
  local -a failed=()
  for p in "${todo[@]}"; do
    if $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
         apt-get install -y -qq --no-install-recommends "$p"; then
      ok "[$name] $p"
    else
      warn "[$name] '$p' failed to install"
      failed+=("$p")
    fi
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    err "[$name] install failed for ${#failed[@]} package(s): ${failed[*]}"
    return 1
  fi
  ok "[$name] installed"
  return 0
}

# ---- Pre-flight -------------------------------------------------------------
preflight() {
  say ""
  printf '%s%s' "$M" "$BD"
  cat <<'BANNER'
+----------------------------------------------------------+
|  agent-box: agentic toolbox for Ubuntu                   |
|  Stage 1 Ubuntu packages, Stage 2 Python packages,      |
|  Stage 3 shell conveniences, Stage 4 command aliases.   |
|  Every step asks before it acts.                        |
+----------------------------------------------------------+
BANNER
  printf '%s' "$N"
  say ""
  [ "$DRY_RUN" = true ] && warn "Dry run. Nothing is installed and nothing is written."
  info "Log: $LOG_FILE"

  case "$(uname -s)" in
    Linux*) : ;;
    *) err "This script targets Linux. Detected: $(uname -s)"; return 1 ;;
  esac
  if ! command -v apt-get >/dev/null 2>&1; then
    err "No apt-get. This installer supports Ubuntu and Debian only."
    return 1
  fi
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "Distro: ${PRETTY_NAME:-$ID}"
    case "${ID:-}${ID_LIKE:-}" in
      *ubuntu*|*debian*) : ;;
      *) warn "Not Ubuntu or Debian (${ID:-unknown}). Package names may not match." ;;
    esac
  fi
  info "User: $(id -un) (uid $(id -u)). sudo: ${SUDO:-<root>}"
  if [ -n "$PY_PACKAGES" ]; then
    info "Python packages: $(printf '%s' "$PY_PACKAGES" | wc -w) requested"
  fi
  return 0
}

# ---- Stage 1: Ubuntu packages (required) ------------------------------------
stage_one() {
  say ""
  say "${BD}Stage 1 - Ubuntu packages [required]${N}"

  if [ "$NO_PACKAGES" = true ]; then
    info "Stage 1 skipped by request (--no-packages)."
    return 0
  fi

  local -a groups=(base python search inspect git data net dev docs media x11 secrets)
  local -a optional=(headless containers databases net-scan docs-full monitor desktop-build shell-history)
  if [ "$MINIMAL" = true ]; then
    groups=(base python search git dev x11 secrets)
    info "Minimal mode: ${groups[*]}. Optional groups are all declined."
    optional=()
  fi
  # --assume yes would accept every prompt, optional groups included. This flag
  # is how a scripted run takes the required groups and nothing else.
  if [ "$NO_OPTIONAL" = true ] && [ "${#optional[@]}" -gt 0 ]; then
    info "Optional groups skipped by request (--no-optional)."
    optional=()
  fi

  say "Required groups :"
  local g
  for g in "${groups[@]}"; do
    printf '  %-14s %s\n' "$g" "$(group_desc "$g")"
  done
  if [ "${#optional[@]}" -gt 0 ]; then
    say "Optional groups :"
    for g in "${optional[@]}"; do
      printf '  %-14s %s\n' "$g" "$(group_desc "$g")"
    done
  fi

  if ! ask_yes_no "Install the required Ubuntu package groups now? [Y/n]" y; then
    warn "Stage 1 skipped. Nothing was installed."
    return 0
  fi

  local rc=0
  for g in "${groups[@]}"; do
    install_group "$g" || rc=1
  done

  for g in "${optional[@]}"; do
    if ask_yes_no "Install the optional group '$g'? [y/N]" n; then
      install_group "$g" || warn "[$g] failed. This group is optional, so the run continues."
    else
      info "Skipping optional group '$g'."
    fi
  done

  if [ "$rc" -ne 0 ]; then
    err "Stage 1 failed. One or more required package groups did not install."
    return 1
  fi
  ok "Stage 1 complete."
  return 0
}

# ---- Stage 2: Python packages (required) ------------------------------------
stage_two() {
  say ""
  say "${BD}Stage 2 - Python packages [required]${N}"

  if [ "$NO_PYTHON" = true ]; then
    info "Stage 2 skipped by request (--no-python)."
    return 0
  fi

  say "Virtual environment : $PY_VENV"
  say "Packages            : $(printf '%s' "$PY_PACKAGES" | wc -w)"
  say "These go into a virtual environment, not into the system Python."

  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 not found. Install Stage 1 group 'python' first, then re-run."
    return 1
  fi
  if ! ask_yes_no "Create the virtual environment and install these Python packages? [Y/n]" y; then
    warn "Stage 2 skipped. Nothing was installed into Python."
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    say "  would run: python3 -m venv $PY_VENV"
    say "  would run: $PY_VENV/bin/python -m pip install --upgrade <packages>"
    return 0
  fi

  # Reuse an existing environment. Recreating it every run would silently drop
  # packages the user installed by hand.
  if [ ! -x "$PY_VENV/bin/python" ]; then
    info "Creating the virtual environment at $PY_VENV"
    if ! python3 -m venv "$PY_VENV"; then
      err "Could not create the virtual environment at $PY_VENV"
      return 1
    fi
  else
    info "Reusing the existing virtual environment at $PY_VENV"
  fi
  if [ ! -x "$PY_VENV/bin/python" ]; then
    err "The virtual environment has no interpreter at $PY_VENV/bin/python"
    return 1
  fi

  info "Installing Python packages"
  # shellcheck disable=SC2086
  if "$PY_VENV/bin/python" -m pip install --upgrade $PY_PACKAGES; then
    ok "Python packages installed in $PY_VENV"
    return 0
  fi
  # A single bad name should not cost the whole stage. Retry one at a time.
  warn "Retrying one package at a time"
  local -a failed=()
  local p
  for p in $PY_PACKAGES; do
    if "$PY_VENV/bin/python" -m pip install --upgrade "$p"; then
      ok "py $p"
    else
      warn "py '$p' failed to install"
      failed+=("$p")
    fi
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    err "Stage 2 failed for ${#failed[@]} package(s): ${failed[*]}"
    return 1
  fi
  ok "Python packages installed in $PY_VENV"
  return 0
}

# ---- Stage 3: shell conveniences (optional) --------------------------------
# Adds starship and zoxide to the shell rc file, and points git at delta.
# Every edit is guarded by a marker, so re-running changes nothing.
# Remove a previously written agent-box block, markers included. Rewriting the
# block instead of skipping when it exists is what makes this stage self-healing:
# a run before starship was installed would otherwise leave a block with no
# init lines, and the marker would freeze that gap in forever.
strip_block() {
  local rcfile="$1" tmp
  grep -q '# >>> agent-box.sh >>>' "$rcfile" 2>/dev/null || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/agent-box-rc.XXXXXX")" || return 1
  awk '
    /# >>> agent-box.sh >>>/ { skip = 1; next }
    /# <<< agent-box.sh <<</ { skip = 0; next }
    !skip { print }
  ' "$rcfile" >"$tmp" || { rm -f "$tmp"; return 1; }
  # Write through the original file so its permissions and ownership survive.
  cat "$tmp" >"$rcfile" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

stage_three_shell() {
  say ""
  say "${BD}Stage 3 - Shell conveniences [optional]${N}"

  if [ "$NO_SHELL" = true ]; then
    info "Stage 3 skipped by request (--no-shell)."
    return 0
  fi

  local rcfile="$HOME/.bashrc"
  [ -n "${ZSH_VERSION:-}" ] && rcfile="$HOME/.zshrc"
  say "rc file : $rcfile"
  say "Writes one marked block: bash completion, starship prompt, zoxide jump."
  say "Also points git at delta as its pager."

  if ! ask_yes_no "Write that block to $rcfile and set the git pager? [y/N]" n; then
    info "Stage 3 skipped. No shell file was changed."
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    say "  would rewrite the marked block in $rcfile"
    say "  would run: git config --global core.pager delta"
    return 0
  fi

  if strip_block "$rcfile"; then
    info "Removed the previous agent-box block from $rcfile. Rewriting it."
  else
    info "No previous agent-box block in $rcfile. Adding one."
  fi

  if {
    printf '\n# >>> agent-box.sh >>>\n'
    printf '# Written by agent-box.sh. Edits inside the markers are replaced on re-run.\n'
    printf '[ -f /etc/bash_completion ] && . /etc/bash_completion\n'
    # Single quotes on purpose: the rc file must receive the literal command
    # substitution, not this script's expansion of it.
    # shellcheck disable=SC2016
    if command -v starship >/dev/null 2>&1; then
      # shellcheck disable=SC2016
      printf 'eval "$(starship init bash)"\n'
    else
      printf '# starship not installed, no prompt init\n'
    fi
    if command -v zoxide >/dev/null 2>&1; then
      # shellcheck disable=SC2016
      printf 'eval "$(zoxide init bash)"\n'
    else
      printf '# zoxide not installed, no jump init\n'
    fi
    printf '# <<< agent-box.sh <<<\n'
  } >>"$rcfile"; then
    ok "Wrote the agent-box block to $rcfile"
  else
    warn "Could not write to $rcfile. Skipping the shell block."
  fi

  if command -v delta >/dev/null 2>&1; then
    if git config --global core.pager delta 2>/dev/null; then
      ok "git pager set to delta"
    else
      warn "Could not set the git pager. Skipping."
    fi
  else
    info "git-delta not installed, leaving the git pager alone."
  fi
  return 0
}

# ---- Stage 4: command aliases (optional) ------------------------------------
# Ubuntu ships fd as fdfind and bat as batcat. Agents type the short names, so
# link both into ~/.local/bin when the short name is free.
stage_four_aliases() {
  say ""
  say "${BD}Stage 4 - Command aliases [optional]${N}"

  if [ "$NO_ALIASES" = true ]; then
    info "Stage 4 skipped by request (--no-aliases)."
    return 0
  fi

  say "Links fdfind -> fd and batcat -> bat in $BINDIR, if the short names are free."

  if ! ask_yes_no "Create those command aliases? [y/N]" n; then
    info "Stage 4 skipped. No aliases were created."
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    say "  would link $BINDIR/fd and $BINDIR/bat"
    return 0
  fi

  mkdir -p "$BINDIR" || { warn "Could not create $BINDIR. Skipping the aliases."; return 0; }
  local rc=0 pair src dst
  for pair in "fdfind:fd" "batcat:bat"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    if ! command -v "$src" >/dev/null 2>&1; then
      info "$src not installed, no alias for $dst."
      continue
    fi
    if command -v "$dst" >/dev/null 2>&1; then
      info "$dst already exists, leaving it alone."
      continue
    fi
    if ln -sf "$(command -v "$src")" "$BINDIR/$dst"; then
      ok "$BINDIR/$dst -> $(command -v "$src")"
    else
      warn "Could not link $dst to $src"
      rc=1
    fi
  done
  return "$rc"
}

# ---- Stage 5: verification --------------------------------------------------
# Never fails the run. A missing tool is reported, not treated as an error.
#
# "cmd flag" pairs. The flag is the one that tool actually accepts: nc, xrandr,
# xdpyinfo, xwininfo, and csvtool have no version flag at all, so they are
# listed with no flag and reported as present. Guessing --version for those
# printed their usage errors as if they were version strings.
VERIFY_LIST="rg:--version rga:--version fd:--version fzf:--version bat:--version
ag:--version tree:--version eza:--version lsd:--version
jq:--version yq:--version mlr:--version csvtool: sqlite3:--version
git:--version delta:--version gh:--version
curl:--version wget:--version nc: socat:-V dig:-v ping:-V
traceroute:--version mtr:--version
shellcheck:--version shfmt:--version pre-commit:--version direnv:version
htop:--version btop:--version procs:--version ncdu:--version lsof:-v ss:-V
pdftotext:-v pdfinfo:-v qpdf:--version
ffmpeg:-version import:-version identify:-version xrandr: xdpyinfo:
xdotool:--version wmctrl:--version xclip:-version xsel:--version scrot:--version xwininfo:
age:--version pass: starship:--version zoxide:--version atuin:--version
uv:--version ruff:--version pytest:--version http:--version
python3:--version node:--version npm:--version"

# Find a tool on PATH, then in the Stage 2 virtual environment. uv and the rest
# of the venv tools are installed but not on PATH until the venv is activated,
# so a PATH-only lookup would report them missing right after installing them.
find_tool() {
  local cmd="$1" p
  p="$(command -v "$cmd" 2>/dev/null || true)"
  if [ -z "$p" ] && [ -x "$PY_VENV/bin/$cmd" ]; then
    p="$PY_VENV/bin/$cmd"
  fi
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

# Print one clean version line, or nothing. A tool that rejects its flag gets
# an empty string, which prints as a presence-only row rather than as an error
# message wearing a version's clothes.
tool_version() {
  local path flag out=""
  path="$(find_tool "$1")" || return 1
  flag="$2"
  if [ -n "$flag" ]; then
    if command -v timeout >/dev/null 2>&1; then
      out="$(timeout 5 "$path" "$flag" 2>&1 || true)"
    else
      out="$("$path" "$flag" 2>&1 || true)"
    fi
  fi
  out="$(printf '%s\n' "$out" \
    | head -1 \
    | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/[[:space:]]*$//' \
    | cut -c1-58)"
  case "$out" in
    *"unrecognized argument"*|*"unrecognised argument"*|*"unrecognized option"*|\
    *"invalid option"*|*"illegal option"*|*"unknown option"*|*"requires an argument"*|\
    *"no such file"*|*"I/O Error"*|*"usage:"*|*"Usage:"*)
      out=""
      ;;
  esac
  printf '%s' "$out"
}

verify() {
  say ""
  say "${BD}Stage 5 - Verification${N}"
  local entry cmd line missing=0 present=0
  for entry in $VERIFY_LIST; do
    cmd="${entry%%:*}"
    line="$(tool_version "$cmd" "${entry#*:}")"
    if [ -z "$line" ]; then
      if find_tool "$cmd" >/dev/null 2>&1; then
        present=$((present + 1))
        printf '  %sOK%s %-11s %s\n' "$G" "$N" "$cmd" "present"
      else
        missing=$((missing + 1))
        printf '  %s.%s %-11s %s\n' "$Y" "$N" "$cmd" "not found"
      fi
    else
      present=$((present + 1))
      printf '  %sOK%s %-11s %s\n' "$G" "$N" "$cmd" "$line"
    fi
  done
  info "$present tool(s) present, $missing not found."

  if [ -x "$PY_VENV/bin/python" ]; then
    local n
    n="$("$PY_VENV/bin/python" -m pip list --format=freeze 2>/dev/null | wc -l)"
    say "  ${G}OK${N} venv packages: ${n:-0} in $PY_VENV"
  else
    say "  ${Y}.${N} venv not created at $PY_VENV"
  fi

  case ":$PATH:" in
    *":$BINDIR:"*) : ;;
    *) warn "$BINDIR is not on PATH in this shell. Add it, or source the rc file." ;;
  esac
  return 0
}

# ---- Main -------------------------------------------------------------------
# Returns 0 for success. Returns nonzero only when a required stage failed.
main() {
  preflight || { err "Pre-flight failed."; return 1; }

  stage_one          || { err "Required Stage 1 failed. The script stops here."; return 1; }
  stage_two          || { err "Required Stage 2 failed. The script stops here."; return 1; }
  stage_three_shell  || warn "Stage 3 had a problem. The stage is optional, so the run continues."
  stage_four_aliases || warn "Stage 4 had a problem. The stage is optional, so the run continues."
  verify

  say ""
  ok "Done."
  say "  Activate the Python tools with:  ${BD}source $PY_VENV/bin/activate${N}"
  say "  uv, ruff, pytest, httpie, and the rest are in that venv."
  return 0
}

# ---- Entry point ------------------------------------------------------------
# tee on the right side of a pipe hides the exit status of main. PIPESTATUS
# carries the real status of main out of the pipe, so a required stage failure
# still leaves the script with a nonzero exit code.
run_logged() {
  if ! : >>"$LOG_FILE" 2>/dev/null; then
    warn "Log file $LOG_FILE is not writable. Continuing without a log file."
    main
    return $?
  fi
  main 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

run_logged
exit $?