# .ide/Dockerfile
FROM cnbcool/default-dev-env:latest

RUN apt-get update && apt-get install -y \
      gcc libc6-dev libssl-dev strace python3 openssl \
    && rm -rf /var/lib/apt/lists/*

# The MoonBit toolchain.
RUN curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash \
     && "$HOME/.moon/bin/moon" version

# The ClaudeCode && agy && cc-switch
RUN curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash \
     && curl -fsSL https://antigravity.google/cli/install.sh | bash \
     && curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash

RUN wget https://go.dev/dl/go1.27.3.linux-amd64.tar.gz \
     && rm -rf /usr/local/go && tar -C /usr/local -xzf go1.27.3.linux-amd64.tar.gz \
     && rm -rf go1.27.3.linux-amd64.tar.gz

ENV PATH="$PATH:/root/.local/bin:/usr/local/go/bin:/root/.moon/bin" \
     GOPROXY=https://goproxy.cn,direct

RUN go install golang.org/x/tools/gopls@latest \
     && go install honnef.co/go/tools/cmd/staticcheck@latest \
     && go install github.com/go-delve/delve/cmd/dlv@latest

ENV workspace="/workspace"

RUN code-server --install-extension tamasfe.even-better-toml \
     && code-server --install-extension usernamehw.errorlens \
     && code-server --install-extension chanhx.crabviz \
     && code-server --install-extension golang.Go \
     && code-server --install-extension moonbit.moonbit-lang \
     && code-server --install-extension Anthropic.claude-code
