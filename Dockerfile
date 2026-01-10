FROM ubuntu:latest
ENV DEBIAN_FRONTEND=noninteractive

# Install core tools + openssh-server
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gh \
    git \
    gnupg \
    locales \
    openssh-server \
    sudo \
    tzdata \
    unzip \
    wget \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
    
# Deutsche Locale + Zeitzone (optional, aber praktisch)
RUN locale-gen de_DE.UTF-8 && \
    update-locale LANG=de_DE.UTF-8

ENV LANG=de_DE.UTF-8 \
    LANGUAGE=de_DE:de \
    LC_ALL=de_DE.UTF-8 \
    TZ=Europe/Berlin

# R aus offiziellem Debian/Ubuntu-Repo 
RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base \
    r-base-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# Neovim aus Debian/Ubuntu-Repo 
RUN apt-get update && apt-get install -y --no-install-recommends \
    neovim \
    && rm -rf /var/lib/apt/lists/*

# Create required directory for sshd
# Generate SSH host keys (required for sshd to start)
RUN mkdir /var/run/sshd
RUN ssh-keygen -A

# Add GitHub to the known_hosts file so git commands work non-interactively
# We use ssh-keyscan to fetch GitHub's public key and save it.
# this is a trick from https://agileweboperations.com/2025/11/23/how-to-run-opencode-ai-in-a-docker-container/
RUN mkdir -p /home/ubuntu/.ssh \
    && ssh-keyscan github.com >> /home/ubuntu/.ssh/known_hosts

# Configure passwordless sudo for ubuntu user
# this is a trick from Matthias Marschall, too
RUN usermod -aG sudo ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# Enforce key-only authentication + disable root login
RUN sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "PasswordAuthentication no" >> /etc/ssh/sshd_config \
    && echo "KbdInteractiveAuthentication no" >> /etc/ssh/sshd_config \
    && echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config \
    && echo "PermitRootLogin no" >> /etc/ssh/sshd_config \
    && echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config

# Fix common container SSH issue with pam_loginuid
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

# Switch to non-root user
USER ubuntu
WORKDIR /home/ubuntu

# Pre-create .ssh directory
# Copy your authorized_keys (public key(s)) into the image
# Assumes file is named 'authorized_keys' in build context
# Enforce strict permissions (critical for SSH to accept the file)
RUN mkdir -p /home/ubuntu/.ssh
COPY --chown=ubuntu:ubuntu authorized_keys /home/ubuntu/.ssh/authorized_keys
RUN chmod 600 /home/ubuntu/.ssh/authorized_keys

# Pre-create OpenCode config/auth directories + correct ownership
RUN mkdir -p /home/ubuntu/.local/share/opencode \
    && chown -R ubuntu:ubuntu /home/ubuntu/.local/share/opencode
RUN mkdir -p /home/ubuntu/.config/opencode \
    && chown -R ubuntu:ubuntu /home/ubuntu/.config/opencode

# Install OpenCode AI via official script
RUN curl -fsSL https://opencode.ai/install | bash

# Inform Docker that the container listens on SSH port (you still need -p at runtime)
EXPOSE 22

# provide github token, must be provided to docker run
RUN echo 'export GITHUB_TOKEN="${GITHUB_TOKEN}"' >> /home/ubuntu/.bashrc


USER root

# Install Air (R formatter) system-wide
RUN curl -LsSf https://github.com/posit-dev/air/releases/latest/download/air-installer.sh | sh \
  && cp /root/.local/bin/air /usr/local/bin/air \
  && rm -rf /root/.local \ 
  && air --version 
  
# healthcheck
HEALTHCHECK --interval=60s --timeout=20s --start-period=120s --retries=3 \
    CMD bash -c 'echo -n > /dev/tcp/127.0.0.1/22' || exit 1

CMD /usr/sbin/sshd -t && exec /usr/sbin/sshd -D -e

