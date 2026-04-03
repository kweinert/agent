FROM ubuntu:24.04

USER root

## System basics 
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server python3 python3-pip git wget unzip curl tmux less \
        r-base r-base-dev libcurl4-openssl-dev \
        libcurl4 libxml2-dev libssl-dev build-essential xclip ripgrep fd-find fzf \
		cmake libuv1-dev pandoc poppler-data libpoppler-cpp-dev \
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
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    echo "" >> /etc/ssh/sshd_config && \
    echo "# SSH hardening" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config && \
    echo "KbdInteractiveAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AllowUsers agent nert" >> /etc/ssh/sshd_config && \
    sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd

## DuckDB 
RUN DUCKDB_VERSION=$(curl -s https://api.github.com/repos/duckdb/duckdb/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/') && \
    wget "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" && \
    unzip duckdb_cli-linux-amd64.zip -d /usr/local/bin/ && \
    rm duckdb_cli-linux-amd64.zip && \
    chmod +x /usr/local/bin/duckdb

## Lea
RUN pip3 install --no-cache-dir --break-system-packages lea-cli duckdb

## lazygit 
RUN LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/') && \
    curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" && \
    tar xf lazygit.tar.gz lazygit && \
    install lazygit /usr/local/bin && \
    rm lazygit.tar.gz lazygit

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
RUN echo "set -g mouse on" > /etc/tmux.conf && \
    echo "set -g history-limit 50000" >> /etc/tmux.conf && \
    echo "set -g default-terminal \"screen-256color\"" >> /etc/tmux.conf && \
    echo "set -sg escape-time 10" >> /etc/tmux.conf && \
    echo "setw -g mode-keys vi" >> /etc/tmux.conf && \
    echo 'if [ -z "$TMUX" ] && [[ $- == *i* ]]; then exec tmux new-session -A -s main; fi' >> /home/agent/.bashrc && \
    echo 'if [ -z "$TMUX" ] && [[ $- == *i* ]]; then exec tmux new-session -A -s main; fi' >> /home/nert/.bashrc && \
    echo 'export GITHUB_TOKEN="${GITHUB_TOKEN}"' >> /home/agent/.bashrc && \
    echo 'export GITHUB_TOKEN="${GITHUB_TOKEN}"' >> /home/nert/.bashrc

## R Configuration (Using PPM Binaries)
RUN R_VERSION=$(R --version | head -n 1 | sed -E 's/.*version ([0-9]+\.[0-9]+).*/\1/') && \
    echo "Detected R version: $R_VERSION" && \
    echo "options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/noble/latest'), pkg.type = 'binary')" >> /usr/lib/R/etc/Rprofile.site && \
    echo "" >> /usr/lib/R/etc/Rprofile.site && \
    echo "# Custom q() that does not ask to save workspace by default" >> /usr/lib/R/etc/Rprofile.site && \
    echo "utils::assignInNamespace(" >> /usr/lib/R/etc/Rprofile.site && \
    echo "  'q'," >> /usr/lib/R/etc/Rprofile.site && \
    echo "  function(save = 'no', status = 0, runLast = TRUE) {" >> /usr/lib/R/etc/Rprofile.site && \
    echo "    .Internal(quit(save, status, runLast))" >> /usr/lib/R/etc/Rprofile.site && \
    echo "  }," >> /usr/lib/R/etc/Rprofile.site && \
    echo "  'base'" >> /usr/lib/R/etc/Rprofile.site && \
    echo ")" >> /usr/lib/R/etc/Rprofile.site && \
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
CMD ["/bin/bash", "-c", "ssh-keygen -A && mkdir -p /var/run/sshd && /usr/sbin/sshd -D"]

