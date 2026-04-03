FROM ubuntu:24.04

## System basics 
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server python3 python3-pip git wget unzip curl tmux less \
        r-base r-base-dev libcurl4-openssl-dev \
        libcurl4 libxml2-dev libssl-dev build-essential xclip ripgrep fd-find fzf \
        sudo gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s $(which fdfind) /usr/local/bin/fd

## Neovim 
RUN curl -LO https://github.com/neovim/neovim/releases/download/v0.10.4/nvim-linux-x86_64.tar.gz && \
    tar -C /opt -xzf nvim-linux-x86_64.tar.gz && \
    ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim && \
    rm nvim-linux-x86_64.tar.gz
	
## Air (R formatter) 
RUN curl -LsSf https://github.com/posit-dev/air/releases/latest/download/air-installer.sh | sh \
    && cp /root/.local/bin/air /usr/local/bin/air \
    && rm -rf /root/.local \
    && air --version

## Create users: agent and nert (with passwordless sudo)
RUN useradd -m -s /bin/bash agent && \
    useradd -m -s /bin/bash nert && \
    usermod -aG sudo nert && \
    echo "nert ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nert && \
    chmod 0440 /etc/sudoers.d/nert

## SSH Setup - ONLY agent and nert allowed, key-only authentication
RUN mkdir -p /var/run/sshd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers agent nert" >> /etc/ssh/sshd_config && \
    sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd

## CLI Tools (DuckDB & Lea)
RUN DUCKDB_VERSION=$(curl -s https://api.github.com/repos/duckdb/duckdb/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/') && \
    wget "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" && \
    unzip duckdb_cli-linux-amd64.zip -d /usr/local/bin/ && \
    rm duckdb_cli-linux-amd64.zip && \
    chmod +x /usr/local/bin/duckdb

RUN pip3 install --no-cache-dir --break-system-packages lea-cli duckdb

## Add lazygit PPA and install via apt (works on Ubuntu 24.04)
RUN apt-get update && \
    apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository ppa:lazygit-team/release -y && \
    apt-get update && \
    apt-get install -y --no-install-recommends lazygit && \
    apt-get purge -y software-properties-common && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*


USER root

## Pre-create OpenCode directories + install OpenCode AI for both users
RUN mkdir -p /home/agent/.local/share/opencode /home/agent/.config/opencode && \
    chown -R agent:agent /home/agent/.local/share/opencode /home/agent/.config/opencode && \
    mkdir -p /home/nert/.local/share/opencode /home/nert/.config/opencode && \
    chown -R nert:nert /home/nert/.local/share/opencode /home/nert/.config/opencode

USER agent
RUN curl -fsSL https://opencode.ai/install | bash

USER nert
RUN curl -fsSL https://opencode.ai/install | bash

USER root

# === Frequently changing customizations start here ===

## Copy authorizedkeys (same public key file works for both users)
COPY authorizedkeys /tmp/authorizedkeys

RUN mkdir -p /home/agent/.ssh /home/nert/.ssh && \
    cp /tmp/authorizedkeys /home/agent/.ssh/authorized_keys && \
    cp /tmp/authorizedkeys /home/nert/.ssh/authorized_keys && \
    chown -R agent:agent /home/agent/.ssh && \
    chown -R nert:nert /home/nert/.ssh && \
    chmod 700 /home/agent/.ssh /home/nert/.ssh && \
    chmod 600 /home/agent/.ssh/authorized_keys /home/nert/.ssh/authorized_keys && \
    rm /tmp/authorizedkeys
	
## Shell UX (Tmux & Bashrc) + GITHUB_TOKEN placeholder for both users
RUN echo "set -g mouse on
set -g history-limit 50000
set -g default-terminal \"screen-256color\"
set -sg escape-time 10
setw -g mode-keys vi" > /etc/tmux.conf && \
    echo 'if [ -z "$TMUX" ] && [[ $- == *i* ]]; then exec tmux new-session -A -s main; fi' >> /home/agent/.bashrc && \
    echo 'if [ -z "$TMUX" ] && [[ $- == *i* ]]; then exec tmux new-session -A -s main; fi' >> /home/nert/.bashrc && \
    echo 'export GITHUB_TOKEN="${GITHUB_TOKEN}"' >> /home/agent/.bashrc && \
    echo 'export GITHUB_TOKEN="${GITHUB_TOKEN}"' >> /home/nert/.bashrc
	

## R Configuration (Using PPM Binaries)
RUN R_VERSION=$(R --version | head -n 1 | sed -E 's/.*version ([0-9]+\.[0-9]+).*/\1/') && \
    echo "Detected R version: $R_VERSION" && \
    echo "options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/noble/latest'), pkg.type = 'binary')" > /usr/lib/R/etc/Rprofile.site && \
    echo '
# Custom q() that does not ask to save workspace by default
utils::assignInNamespace(
  "q",
  function(save = "no", status = 0, runLast = TRUE) {
    .Internal(quit(save, status, runLast))
  },
  "base"
)
' >> /usr/lib/R/etc/Rprofile.site && \
    R -q -e 'install.packages("pak", repos = "https://r-lib.github.io/p/pak/stable")' && \
    R -q -e 'pak::pkg_install(c("remotes", "data.table", "duckdb", "shiny", "bslib", "reactable", "plotly", "pdftools"))'
	
##  Neovim Setup (copy config + sync plugins for both users)
COPY kickstart.nvim /tmp/kickstart.nvim
RUN mkdir -p /home/agent/.config/nvim /home/nert/.config/nvim && \
    cp /tmp/kickstart.nvim /home/agent/.config/nvim/init.lua && \
    cp /tmp/kickstart.nvim /home/nert/.config/nvim/init.lua && \
    chown -R agent:agent /home/agent/.config && \
    chown -R nert:nert /home/nert/.config && \
    rm /tmp/kickstart.nvim

USER agent
RUN nvim --headless "+Lazy! sync" +qa

USER nert
RUN nvim --headless "+Lazy! sync" +qa

## Healthcheck
HEALTHCHECK --interval=60s --timeout=20s --start-period=120s --retries=3 \
    CMD bash -c 'echo -n > /dev/tcp/127.0.0.1/22' || exit 1

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]

