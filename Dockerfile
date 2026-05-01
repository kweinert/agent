FROM ubuntu:24.04

USER root

## System basics 
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server python3 python3-pip git wget unzip curl tmux less htop \
        r-base r-base-dev libcurl4-openssl-dev \
        libcurl4 libxml2-dev libssl-dev build-essential xclip ripgrep fd-find fzf \
		cmake libuv1-dev pandoc poppler-data libpoppler-cpp-dev \
		libopenblas0 libopenblas-dev \
        sudo gh tzdata \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s $(which fdfind) /usr/local/bin/fd

# time zone
ENV TZ=Europe/Berlin
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata

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

# Tokei (count code)
# apt-get cargo does not work
ENV RUSTUP_HOME=/opt/rust
ENV CARGO_HOME=/opt/rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path && \
	/opt/rust/bin/cargo install tokei --root /usr/local && \
	rm -rf /opt/rust

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
    echo "" >> /etc/ssh/sshd_config && \
    echo "# SSH hardening" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config && \
    echo "KbdInteractiveAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AllowUsers agent nert" >> /etc/ssh/sshd_config && \
	echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config && \
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

## Pre-create directories and ensure correct ownership
RUN mkdir -p /home/agent/.local/share /home/agent/.config && \
    mkdir -p /home/nert/.local/share /home/nert/.config && \
    chown -R agent:agent /home/agent && \
    chown -R nert:nert /home/nert

USER agent
WORKDIR /home/agent

# Configure Git 
RUN git config --global credential.helper "!gh auth git-credential" && \
    git config --global user.name "OpenCode Agent" && \
    git config --global user.email "agent@opencode.local"

# opencode
RUN curl -fsSL https://opencode.ai/install | bash

USER root

# === Frequently changing customizations start here ===

## Copy authorizedkeys (same public key file works for both users)
COPY authorizedkeys /tmp/authorizedkeys

## Per-user GitHub tokens for SSH login shells
RUN echo 'GITHUB_TOKEN_AGENT' >> /etc/environment && \
    echo 'GITHUB_TOKEN_NERT'   >> /etc/environment

RUN mkdir -p /home/agent/.ssh /home/nert/.ssh && \
    cp /tmp/authorizedkeys /home/agent/.ssh/authorized_keys && \
    cp /tmp/authorizedkeys /home/nert/.ssh/authorized_keys && \
    chown -R agent:agent /home/agent/.ssh && \
    chown -R nert:nert /home/nert/.ssh && \
    chmod 700 /home/agent/.ssh /home/nert/.ssh && \
    chmod 600 /home/agent/.ssh/authorized_keys /home/nert/.ssh/authorized_keys && \
    rm /tmp/authorizedkeys
	
## tmux
COPY tmux.conf /etc/tmux.conf
RUN echo 'if [ -z "$TMUX" ] && [[ $- == *i* ]]; then exec tmux new-session -A -s main; fi' >> /home/agent/.bashrc && \
    echo 'if [ -z "$TMUX" ] && [[ $- == *i* ]]; then exec tmux new-session -A -s main; fi' >> /home/nert/.bashrc && \
	chown -R agent:agent /home/agent/.bashrc && \
    chown -R nert:nert /home/nert/.bashrc

# opencode
RUN mkdir -p /home/agent/.config && chown agent:agent /home/agent/.config
COPY --chown=agent:agent opencode/ /home/agent/.config/opencode/

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
    R -q -e 'pak::pkg_install(c("remotes", "data.table", "duckdb", "shiny", "bslib", "reactable", "plotly", "pdftools", \
		"RhpcBLASctl", "nanoparquet", "httr", "jsonlite", "R.utils", "roxygen2"))'

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

## sshd requires root
USER root
HEALTHCHECK --interval=60s --timeout=20s --start-period=120s --retries=3 \
    CMD bash -c 'echo -n > /dev/tcp/127.0.0.1/22' || exit 1
EXPOSE 22

## Entrypoint 
RUN echo '#!/bin/bash' > /usr/local/bin/entrypoint.sh && \
	echo 'echo "GH_TOKEN=${GITHUB_TOKEN_AGENT}" > /home/agent/.ssh/environment' >> /usr/local/bin/entrypoint.sh && \
	echo 'echo "GH_TOKEN=${GITHUB_TOKEN_NERT}" > /home/nert/.ssh/environment' >> /usr/local/bin/entrypoint.sh && \
	echo 'chown agent:agent /home/agent/.ssh/environment' >> /usr/local/bin/entrypoint.sh && \
	echo 'chown nert:nert /home/nert/.ssh/environment' >> /usr/local/bin/entrypoint.sh && \
	echo 'chmod 600 /home/agent/.ssh/environment /home/nert/.ssh/environment' >> /usr/local/bin/entrypoint.sh && \
	echo 'exec /usr/sbin/sshd -D' >> /usr/local/bin/entrypoint.sh && \
	chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]


