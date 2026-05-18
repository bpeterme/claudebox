FROM ubuntu:24.04
# FROM ubuntu:26.04 - playwright not ready yet

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
    btop \
    htop \
    iotop

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs

RUN npm install -g @anthropic-ai/claude-code

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh

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

# playwright — installs Python package and its own Chromium binary
# Enable with: cbox rebuild (after setting BUILD_PLAYWRIGHT=1 in ~/.config/claudebox/cbox.env)
ARG BUILD_PLAYWRIGHT=0
RUN if [ "$BUILD_PLAYWRIGHT" = "1" ]; then \
      uv tool install playwright && \
      playwright install --with-deps chromium; \
    fi

WORKDIR /Workspace
CMD ["/bin/zsh"]
