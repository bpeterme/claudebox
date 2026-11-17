FROM ubuntu:26.04

# cbox removes old images of its own after a rebuild (and at cbox prune) by
# this label, so it never touches other images on the machine.
LABEL cbox.image=true

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    git \
    git-crypt \
    openssh-client \
    zsh \
    sudo \
    ripgrep \
    fd-find \
    build-essential \
    python3 \
    python3-pip \
    ca-certificates \
    gnupg \
    nano \
    jq \
    bats \
    shellcheck \
    btop \
    htop \
    iotop \
    sox \
    libsox-fmt-pulse \
    pulseaudio-utils \
    libasound2-plugins

# git-crypt writes its own absolute path into .git/config at `git-crypt init`
# (e.g. /opt/homebrew/bin/git-crypt on a Mac). That config is shared with the
# host and read-only in here, so point git at the container's git-crypt instead.
# Environment config outranks the repository's own config, whatever host path
# it names, and only takes effect in repos whose .gitattributes use the filter.
ENV GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=filter.git-crypt.smudge \
    GIT_CONFIG_VALUE_0="git-crypt smudge" \
    GIT_CONFIG_KEY_1=filter.git-crypt.clean \
    GIT_CONFIG_VALUE_1="git-crypt clean" \
    GIT_CONFIG_KEY_2=diff.git-crypt.textconv \
    GIT_CONFIG_VALUE_2="git-crypt diff"

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs

# npm doesn't fail this install if a platform-native optionalDependency
# fails to download, so verify both binaries actually work here — otherwise
# a silently broken image only surfaces later when a container is entered.
RUN npm install -g @anthropic-ai/claude-code opencode-ai && \
    claude --version && \
    opencode --version

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh

# Route ALSA default device through PulseAudio so voice mode works via PULSE_SERVER
RUN printf 'pcm.!default {\n    type pulse\n}\nctl.!default {\n    type pulse\n}\n' > /etc/asound.conf

ARG HOST_UID=1000
# claude gets the host user's UID, so files it writes in the workspace belong
# to the host user. Ubuntu's image already has a user with UID 1000 (ubuntu),
# which is also the usual first user on Linux and WSL: remove it first.
RUN existing=$(getent passwd "$HOST_UID" | cut -d: -f1) && \
    if [ -n "$existing" ]; then userdel -r "$existing" 2>/dev/null || userdel "$existing"; fi && \
    useradd -ms /bin/zsh -u $HOST_UID claude && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# eza (modern ls replacement)
RUN case $(uname -m) in \
      x86_64)  ARCH="x86_64" ;; \
      aarch64) ARCH="aarch64" ;; \
    esac && \
    curl -fsSL "https://github.com/eza-community/eza/releases/latest/download/eza_${ARCH}-unknown-linux-gnu.tar.gz" \
    | tar xz -C /usr/local/bin

# flux (Git + DVC auto-router). Its hooks (pre-commit, pre-push) come with the
# project's bind-mounted .git/hooks and only need `dvc` (below) on PATH. This
# copy is a fallback: at each session start cbox replaces it with the host's
# own flux when that differs (_cbox_flux_install), so both run the same version.
# Storage access for DVC comes from warden on the host; no keys in here.
RUN curl -fsSL -o /usr/local/bin/flux https://raw.githubusercontent.com/bpeterme/flux/main/flux && \
    chmod +x /usr/local/bin/flux

# zsh plugins
RUN git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
        /home/claude/.zsh/zsh-autosuggestions && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
        /home/claude/.zsh/zsh-syntax-highlighting && \
    chown -R claude:claude /home/claude/.zsh

# Browser location for playwright — deliberately NOT the default
# ~/.cache/ms-playwright: an explicit path keeps installs inspectable and gives
# cbox a stable path to bind-mount the host cache over (see _cbox_create).
# Created before `USER claude`, owned by claude, so installs (in an image
# addition or at run time) can write it without sudo.
RUN mkdir -p /opt/ms-playwright && chown claude:claude /opt/ms-playwright

USER claude

RUN mkdir -p /home/claude/.ssh && chmod 700 /home/claude/.ssh

# Claude Code's session registry on the container's own disk; ~/.claude/sessions
# links here (see _cbox_sessions_link in cbox.sh). Sessions recreate it too.
RUN mkdir -p -m 700 /home/claude/.local/state/claude-sessions

# .zshrc loader
RUN printf '[ -f /home/claude/.zshrc.global ] && . /home/claude/.zshrc.global\n[ -f /home/claude/.zshrc.local ] && . /home/claude/.zshrc.local\n' \
    > /home/claude/.zshrc

# uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --no-modify-path
ENV PATH="/home/claude/.local/bin:$PATH"

# Project venvs live in the bind-mounted workspace, which the host uses too.
# A container-built .venv holds Linux binaries and a /usr/bin/python3 link that
# break the host (and vice versa), so the container gets its own env per project.
# Relative paths resolve against the project root (an absolute path would be
# shared by every project), and uv writes a `*` .gitignore inside the env, so
# neither repos nor the host's git config need an ignore entry.
ENV UV_PROJECT_ENVIRONMENT=.venv-linux

# dvc — required by flux for R2-routed files
RUN uv tool install "dvc[s3]"

# Playwright's browsers go to /opt/ms-playwright, which cbox mounts from a
# cache on the host (CBOX_PLAYWRIGHT_DIR): downloaded once per machine. To bake
# Chromium into the image instead, see the README ("Your own additions").
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

WORKDIR /Workspace
CMD ["/bin/zsh"]
