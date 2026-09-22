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

# Browser location for playwright — deliberately NOT the default
# ~/.cache/ms-playwright. In an image built with BUILD_PLAYWRIGHT=1, the apt
# payload from `playwright install --with-deps` was present while the browser
# binaries were not: ~/.cache/ms-playwright was empty and /root/.cache/ms-playwright
# did not exist at all. The root cause was not determinable from inside the
# container; an explicit non-cache path makes it moot, keeps the result
# inspectable, and gives cbox a stable path to bind-mount the host cache over
# (see _cbox_create in cbox.sh).
#
# Created here — before `USER claude`, owned by claude — so that both the
# build-time install below and any runtime install can write it without sudo.
RUN mkdir -p /opt/ms-playwright && chown claude:claude /opt/ms-playwright

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

# playwright — installs Chromium into PLAYWRIGHT_BROWSERS_PATH
# Enable with: cbox rebuild (after setting BUILD_PLAYWRIGHT=1 in ~/.config/claudebox/cbox.env)
#
# Deliberately unpinned, like the dvc install above. Playwright ties each of its
# releases to one exact Chromium build id, and this image is built on a different
# clock from the one a script resolves playwright on at run time (e.g. an
# unpinned PEP 723 header under `uv run`). A pin here would only drift against
# those scripts and would have to be hand-synced. When they drift, the failure
# reads "Looks like Playwright was just installed or updated" — which sounds
# transient and is not.
#
# So this layer is a warm cache, not a contract: a script that finds its browser
# missing is expected to install a matching one itself, which keeps the two
# clocks self-correcting.
#
# Install and smoke test share a single `uv run`, so the build cannot resolve one
# playwright for the install and a different one for the check. The test launches
# channel="chromium" rather than the headless_shell build, because that is what
# real fetchers use — headless_shell is fingerprinted and refused by Cloudflare.
ARG BUILD_PLAYWRIGHT=0
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN if [ "$BUILD_PLAYWRIGHT" = "1" ]; then \
      uv run --no-project --with playwright python -c "\
import subprocess, sys; \
subprocess.run([sys.executable, '-m', 'playwright', 'install', '--with-deps', 'chromium'], check=True); \
from playwright.sync_api import sync_playwright; \
p = sync_playwright().start(); \
b = p.chromium.launch(channel='chromium', args=['--no-sandbox']); \
print('chromium ok:', b.version); \
b.close(); p.stop()"; \
    fi

WORKDIR /Workspace
CMD ["/bin/zsh"]
