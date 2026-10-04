# agent-box.sh

One-shot installer for a curated agentic CLI toolbox on a fresh Ubuntu box.

It installs the small, fast tools a coding agent reaches for constantly
(`rg`, `fd`, `fzf`, `bat`, `jq`, `yq`, `gh`, `delta`, `xdotool`, `pdftotext`,
and friends), plus a Python virtual environment of wheel-only agent packages
(`httpx`, `pydantic`, `typer`, `rich`, `textual`, `psutil`, `pypdf`, `ruff`,
`pytest`, `uv`, ...).

It does not install a harness. Hermes, pi, or anything else stays your
choice; this script only prepares the machine they drive.

---

## Requirements

- Linux, Ubuntu or Debian family (`apt-get` present)
- root, or `sudo` available
- Tested on Ubuntu 26.04 with Python 3.14

Anything else exits nonzero with a clear message instead of guessing.

## Install

```bash
./agent-box.sh              # guided: asks before each group
./agent-box.sh --all        # accept every prompt and optional step
./agent-box.sh --minimal    # small set: base, python, search, git, dev, x11, secrets
./agent-box.sh --dry-run    # print the full plan, change nothing
```

Then activate the Python tools:

```bash
source ~/.agentbox-venv/bin/activate
```

## What it does, stage by stage

| Stage | What | Failure behavior |
|---|---|---|
| 1 | Ubuntu package groups | required, nonzero exit |
| 2 | Python packages into `~/.agentbox-venv` | required, nonzero exit |
| 3 | `~/.bashrc` block + git delta pager | optional, warns |
| 4 | `fd` / `bat` symlinks in `~/.local/bin` | optional, warns |
| 5 | Verification table of 61 tools | never fails |

Every stage prompts before it acts. A skip is never an error; only a real
failure inside Stage 1 or Stage 2 produces a nonzero exit code.

---

## Stage 1: Ubuntu packages

Required groups, in install order:

| Group | Packages |
|---|---|
| `base` | curl wget gnupg openssh-client ca-certificates build-essential pkg-config cmake meson make unzip zip xz-utils tar rsync file patch bzip2 jq less nano vim-tiny tmux screen man-db manpages locales tzdata lsb-release git-lfs git-delta starship zoxide |
| `python` | python3 python3-venv python3-dev python3-pip python3-setuptools libffi-dev |
| `search` | ripgrep ripgrep-all fd-find fzf bat silversearcher-ag tree eza lsd |
| `inspect` | htop btop procs ncdu lsof psmisc procps iproute2 iputils-ping net-tools |
| `git` | git git-lfs git-delta gh |
| `data` | jq yq miller csvtool sqlite3 |
| `net` | netcat-openbsd socat bind9-dnsutils iputils-ping traceroute mtr openssl |
| `dev` | shellcheck shfmt pre-commit direnv patch |
| `docs` | poppler-utils qpdf |
| `media` | ffmpeg imagemagick alsa-utils |
| `x11` | xdotool wmctrl x11-utils x11-xserver-utils xauth xclip xsel scrot dbus-x11 at-spi2-core libnotify-bin xdg-utils fonts-liberation fonts-dejavu-core fonts-noto-color-emoji |
| `secrets` | gnome-keyring libsecret-1-0 libsecret-tools age pass |

Optional groups, each asked on its own, all defaulting to **no**:

| Group | Packages | Notes |
|---|---|---|
| `headless` | xvfb x11vnc openbox fluxbox xterm | headless X for computer use |
| `containers` | podman podman-docker uidmap slirp4netns fuse-overlayfs | |
| `databases` | redis-tools postgresql-client default-mysql-client | |
| `net-scan` | nmap whois | |
| `docs-full` | pandoc tesseract-ocr | format conversion, OCR |
| `monitor` | glances | whole-box monitoring |
| `desktop-build` | libgtk-3-0 libnotify4 libxtst6 rpm fakeroot dpkg-dev | packaging GUI apps |
| `shell-history` | atuin | searchable shell history |

`--minimal` installs only `base python search git dev x11 secrets` and
declines every optional group. `--no-optional` keeps the full required set
but skips every optional group without asking.

### Renamed packages are handled, not hardcoded

Ubuntu renames packages often. Since 24.04 the 64-bit `time_t` transition
renamed `libasound2` to `libasound2t64`, `libatk1.0-0` to `libatk1.0-0t64`,
`libgtk-3-0` to `libgtk-3-0t64`, and so on.

The script never assumes a name exists. It reads the apt **candidate**, not
the package record: `apt-cache show` still succeeds for a dead entry whose
candidate is `(none)`, which is exactly what causes
`E: Package 'libasound2' has no installation candidate`. Unresolvable names
are dropped with one compact warning and the group continues:

```
! [browser] no install candidate, skipped: libatk1.0-0 libcups2
```

Resolution tries `foo` -> `foo-t64` -> `foot64` and back, because some
packages gained the suffix with a hyphen and some without.

## Stage 2: Python packages

Installs into a dedicated virtual environment (`~/.agentbox-venv`), never
into the system Python.

- **HTTP and CLI**: requests, httpx, httpie
- **Interfaces**: pydantic, pydantic-settings, typer, rich, prompt-toolkit, textual
- **Templates and config**: jinja2, pyyaml, tomli-w, jsonschema, python-dotenv, tenacity
- **Data**: orjson, tqdm, python-dateutil, rapidfuzz, markdown
- **System introspection**: psutil, watchdog
- **Documents**: pypdf, openpyxl, Pillow, python-docx, beautifulsoup4
- **Development**: pytest, ruff, mypy, ipython, ipdb
- **Package manager**: uv

37 requested packages, 88 installed with dependencies. Every one ships a
wheel, so pip never needs a compiler and the stage finishes in seconds.

| Flag | Effect |
|---|---|
| `--py-minimal` | 15 high-value packages instead of 37 |
| `--py-science` | also install numpy and pandas |
| `--py-packages LIST` | replace the whole list |
| `--py-venv DIR` | use a different virtual environment directory |

An existing environment is **reused**, never recreated, so packages you
installed by hand survive a re-run.

## Stage 3: shell conveniences

Writes one marker-delimited block to `~/.bashrc` (or `~/.zshrc`):

```bash
# >>> agent-box.sh >>>
[ -f /etc/bash_completion ] && . /etc/bash_completion
eval "$(starship init bash)"
eval "$(zoxide init bash)"
# <<< agent-box.sh <<<
```

and sets `git config --global core.pager delta`.

The block is **stripped and rewritten** on every accepted run, not appended
once. That makes it self-healing: an early run that predates a tool's
installation does not freeze in a block missing that tool's init lines.

## Stage 4: command aliases

Ubuntu ships `fd` as `fdfind` and `bat` as `batcat`. This stage symlinks the
short names into `~/.local/bin` when they are free, so an agent can type
`fd` and `bat` and get them. It never overwrites an existing command.

## Stage 5: verification

Prints one line per tool with a real version string, marking anything
missing. It uses a per-tool flag table, because `nc`, `socat`, `dig`,
`ping`, `lsof`, `pdftotext`, `xrandr`, `xclip`, `xdpyinfo`, `xwininfo`, and
`csvtool` do not accept `--version`; tools with no version flag are reported
as `present`. Tools are looked up on `PATH` and in the virtual environment,
so `uv` is found even before you activate it.

---

## All options

| Flag | Effect |
|---|---|
| `--minimal` | small required set, no optional groups |
| `--all` | synonym for `--auto`: accept every prompt and optional step |
| `--no-packages` | skip Stage 1 |
| `--no-optional` | required groups only, optional groups never asked |
| `--no-python` | skip Stage 2 |
| `--no-shell` | skip Stage 3, no shell rc edit |
| `--no-aliases` | skip Stage 4 |
| `--py-minimal` | small Python subset |
| `--py-science` | add numpy and pandas |
| `--py-packages LIST` | replace the Python package list |
| `--py-venv DIR` | virtual environment directory |
| `--dry-run` | print every action, change nothing |
| `--auto`, `--yes`, `-y` | assume yes at every prompt, optional groups included |
| `--assume VALUE` | answer every prompt `yes` or `no` |
| `--log FILE` | log file path |
| `-h`, `--help` | usage |

Non-interactive use:

```bash
./agent-box.sh -y                    # accept everything, optional groups too
./agent-box.sh -y --no-optional      # required groups only, no optional prompts
./agent-box.sh -y --no-shell --no-aliases
./agent-box.sh --assume no           # decline every prompt, required ones too
```

`--assume yes` and `--auto` are the same thing: they accept *every* prompt.
Use `--no-optional` when you want the required groups without being asked
about the rest. `--assume no` declines everything including the required
prompts, so the run installs nothing and exits 0.

## Environment overrides

| Variable | Default |
|---|---|
| `PY_VENV` | `$HOME/.agentbox-venv` |
| `PY_PACKAGES` | the built-in list |
| `LOG_FILE` | `$HOME/agent-box.log` |
| `BINDIR` | `$HOME/.local/bin` |
| `WIZARD_ASSUME` | empty (interactive) |

```bash
PY_PACKAGES="httpx pypdf" PY_VENV=/tmp/agentenv ./agent-box.sh --no-packages
```

## What it will not do

- No harness installer (no Hermes, no pi.dev, no `hermes doctor`)
- No shell rc edit unless you accept Stage 3
- No overwrite of an existing command in Stage 4
- No writes outside apt, the virtual environment, `~/.local/bin`, and the
  rc file in Stage 3
- No API endpoint and no API key

## Safety and idempotency

- **Idempotent.** Re-running installs nothing and changes nothing. Only
  missing packages are fetched.
- **Resumable.** Safe on a half-built box. A failed group does not stop the
  script from reporting what did install; only a *required* group failure
  exits nonzero.
- **No `set -e`.** Each stage owns its exit status, so an optional stage can
  never kill the run.
- **Resilient installs.** A bulk `apt-get install` is retried without
  `--no-install-recommends`, then one package at a time, so a single
  conflicting name cannot take down a whole group. Same for `pip`.
- **Logged.** Everything is teed to the log file, with `PIPESTATUS`
  preserving the real exit code. An unwritable log is a warning, not a
  failure.

## Measured timing

| Run | Wall clock |
|---|---|
| Full run, `--all`, partly built box | 9m10s |
| Re-run after three stragglers | 35s |
| Second full re-run (all satisfied) | under a minute |

The first run is dominated by apt downloads, especially podman, nmap,
pandoc, and the database clients. `--minimal` is substantially faster.

## Troubleshooting

**A group reports `no install candidate, skipped: ...`**
That package does not exist under that name on this release. The group
continues without it. Read the rest of the line to see what was skipped.

**`Stage 1 failed` but most groups say `already satisfied`**
One required group had a genuine install failure. The per-package fallback
names the exact packages in the `X` line. Re-run: it is resumable.

**`uv` or `ruff` not found after install**
They are in the virtual environment, not on `PATH`. Either
`source ~/.agentbox-venv/bin/activate` or call them by full path. Stage 5
finds them either way.

**Stage 3 did not add starship or zoxide**
Run it again and accept the prompt. The block is rebuilt from whatever is
installed at that moment.

**`fd` or `bat` still missing**
Ubuntu named them `fdfind` and `batcat`. Accept Stage 4, or call the long
names directly.