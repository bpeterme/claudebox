FROM ubuntu:26.04

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
    btop \
    htop \
    iotop \
    sox \
    libsox-fmt-pulse \
    pulseaudio-utils \
    libasound2-plugins

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
RUN useradd -ms /bin/zsh -u $HOST_UID claude && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# eza (modern ls replacement)
RUN case $(uname -m) in \
      x86_64)  ARCH="x86_64" ;; \
      aarch64) ARCH="aarch64" ;; \
    esac && \
    curl -fsSL "https://github.com/eza-community/eza/releases/latest/download/eza_${ARCH}-unknown-linux-gnu.tar.gz" \
    | tar xz -C /usr/local/bin

# flux (Git + DVC auto-router). The pre-commit hook itself is self-contained
# and doesn't call this binary — it's already present via the bind-mounted
# .git/hooks, and only needs `dvc` (below) on PATH. This binary is here so
# flux's own commands (list, doctor, dry-run, pin, ...) work if run manually
# inside the container; DVC sync for flux-managed projects still runs
# host-side around the container session (see _cbox_enter's flux _pull /
# flux _push calls in cbox.sh).
RUN curl -fsSL -o /usr/local/bin/flux https://raw.githubusercontent.com/bpeterme/flux/main/flux && \
    chmod +x /usr/local/bin/flux

# zsh plugins
RUN git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
        /home/claude/.zsh/zsh-autosuggestions && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
        /home/claude/.zsh/zsh-syntax-highlighting && \
    chown -R claude:claude /home/claude/.zsh

USER claude

RUN mkdir -p /home/claude/.ssh && chmod 700 /home/claude/.ssh

# .zshrc loader
RUN printf '[ -f /home/claude/.zshrc.global ] && . /home/claude/.zshrc.global\n[ -f /home/claude/.zshrc.local ] && . /home/claude/.zshrc.local\n' \
    > /home/claude/.zshrc

# uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --no-modify-path
ENV PATH="/home/claude/.local/bin:$PATH"

# dvc — required by flux for R2-routed files
RUN uv tool install "dvc[s3]"

# playwright — installs Python package and its own Chromium binary
# Enable with: cbox rebuild (after setting BUILD_PLAYWRIGHT=1 in ~/.config/claudebox/cbox.env)
ARG BUILD_PLAYWRIGHT=0
RUN if [ "$BUILD_PLAYWRIGHT" = "1" ]; then \
      uv tool install playwright && \
      playwright install --with-deps chromium; \
    fi

WORKDIR /Workspace
CMD ["/bin/zsh"]
