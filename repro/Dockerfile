# Use minimal Ubuntu base
FROM ubuntu:noble

# Tool versions matching PR check workflow
ENV LUALS_VERSION=3.16.2 \
  STYLUA_VERSION=2.3.1 \
  NVIM_VERSION=0.11.5 \
  DEBIAN_FRONTEND=noninteractive

# Install minimal dependencies, build luacheck, then remove build tools in single layer
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  unzip \
  git \
  lua5.1 \
  luarocks \
  gcc \
  libc6-dev && \
  luarocks install luacheck && \
  apt-get purge -y --auto-remove gcc && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Setup directories
RUN mkdir -p /opt/nvim /opt/luals /usr/local/bin

# Install Neovim (detect architecture)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then NVIM_ARCH="linux-arm64"; else NVIM_ARCH="linux-x86_64"; fi && \
  curl -sL "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-${NVIM_ARCH}.tar.gz" | \
  tar xzf - --strip-components=1 -C /opt/nvim && \
  ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim

# Install LuaLS (detect architecture)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then LUALS_ARCH="linux-arm64"; else LUALS_ARCH="linux-x64"; fi && \
  curl -sL "https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}/lua-language-server-${LUALS_VERSION}-${LUALS_ARCH}.tar.gz" | \
  tar xzf - -C /opt/luals && \
  ln -sf /opt/luals/bin/lua-language-server /usr/local/bin/lua-language-server

# Install StyLua (detect architecture)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then STYLUA_ARCH="linux-aarch64"; else STYLUA_ARCH="linux-x86_64"; fi && \
  curl -sL "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-${STYLUA_ARCH}.zip" -o stylua.zip && \
  unzip -q stylua.zip -d /usr/local/bin/ && \
  chmod +x /usr/local/bin/stylua && \
  rm stylua.zip

WORKDIR /workspace/repro

CMD ["/bin/bash"]
