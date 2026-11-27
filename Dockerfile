# Docker 会自动注入 TARGETARCH 变量
ARG TARGETARCH

# 根据架构选择不同的基础镜像
FROM --platform=linux/amd64 dokken/debian-13:latest AS base-amd64
FROM --platform=linux/arm64 dokken/debian-13:latest AS base-arm64

FROM base-${TARGETARCH}

ARG TARGETARCH

# 版本参数统一放在前面声明
ARG GO_VERSION=1.27.4
ARG ANDROID_CMDLINE_TOOLS_VERSION=16111833
ARG ANDROID_CMDLINE_TOOLS_SHA1=e025545c62a8e64c7559119566a569fb1dec5f60
ARG ANDROID_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=37.0.0
ARG ANDROID_NDK_VERSION=30.0.16248370

WORKDIR /root
USER root

# 基础工具：SSH / JDK / Android 构建所需系统库
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    unzip \
    zip \
    xz-utils \
    openssh-server \
    openjdk-21-jdk-headless \
    libgtk-3-0t64 \
    libgtk-4-1 \
    libwebkit2gtk-4.1-0 \
    libayatana-appindicator3-1 \
    && rm -rf /var/lib/apt/lists/*

# JDK 路径带架构后缀，统一软链成固定路径，避免各用户/脚本写死架构
RUN JDK_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")" \
    && ln -sfn "${JDK_HOME}" /usr/lib/jvm/default-java

RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
 && sed -i 's/#Port 22/Port 6655/' /etc/ssh/sshd_config \
 && sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config \
 && mkdir -p /var/run/sshd \
 && echo 'root:123666' | chpasswd

# Go：GOROOT 固定；模块缓存放 /opt/go；go install 产物直接进 /usr/local/bin
RUN curl -fsSL --retry 3 "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz

# 容器级环境变量：docker exec / sshd 启动的任意用户进程都能继承
ENV GOROOT=/usr/local/go \
    GOPATH=/opt/go \
    GOBIN=/usr/local/bin \
    JAVA_HOME=/usr/lib/jvm/default-java \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/latest \
    ANDROID_NDK_ROOT=/opt/android-sdk/ndk/latest
ENV PATH=/usr/local/go/bin:/usr/local/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/default-java/bin:${PATH}

# 登录 shell 级环境变量：任何用户登录自动加载，覆盖 SSH/bash/login 场景
RUN echo 'export GOROOT=/usr/local/go' > /etc/profile.d/android-go-env.sh \
 && echo 'export GOPATH=/opt/go' >> /etc/profile.d/android-go-env.sh \
 && echo 'export GOBIN=/usr/local/bin' >> /etc/profile.d/android-go-env.sh \
 && echo 'export JAVA_HOME=/usr/lib/jvm/default-java' >> /etc/profile.d/android-go-env.sh \
 && echo 'export ANDROID_HOME=/opt/android-sdk' >> /etc/profile.d/android-go-env.sh \
 && echo 'export ANDROID_SDK_ROOT=/opt/android-sdk' >> /etc/profile.d/android-go-env.sh \
 && echo 'export ANDROID_NDK_HOME=/opt/android-sdk/ndk/latest' >> /etc/profile.d/android-go-env.sh \
 && echo 'export ANDROID_NDK_ROOT=/opt/android-sdk/ndk/latest' >> /etc/profile.d/android-go-env.sh \
 && echo 'export PATH=$GOROOT/bin:$GOBIN:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$JAVA_HOME/bin:$PATH' >> /etc/profile.d/android-go-env.sh \
 && chmod 644 /etc/profile.d/android-go-env.sh

# Android 命令行工具
RUN curl -fsSL --retry 3 \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
      -o /tmp/android-commandlinetools.zip \
    && echo "${ANDROID_CMDLINE_TOOLS_SHA1}  /tmp/android-commandlinetools.zip" | sha1sum -c - \
    && mkdir -p /tmp/android-commandlinetools "${ANDROID_HOME}/cmdline-tools" \
    && unzip -q /tmp/android-commandlinetools.zip -d /tmp/android-commandlinetools \
    && mv /tmp/android-commandlinetools/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm -rf /tmp/android-commandlinetools /tmp/android-commandlinetools.zip

RUN case "$(uname -m)" in \
      x86_64) cli_arch=x86_64 ;; \
      aarch64) cli_arch=arm64 ;; \
      *) echo "unsupported arch: $(uname -m)" >&2 && exit 1 ;; \
    esac \
    && curl -fsSL --retry 3 \
      "https://dl.google.com/android/cli/latest/linux_${cli_arch}/install_root.sh" \
      -o /tmp/android-cli-install.sh \
    && bash /tmp/android-cli-install.sh \
    && rm -f /tmp/android-cli-install.sh \
    && android --version

RUN android --sdk="${ANDROID_HOME}" sdk install \
      platform-tools \
      "platforms/${ANDROID_PLATFORM}" \
      "build-tools/${ANDROID_BUILD_TOOLS}" \
      "ndk/${ANDROID_NDK_VERSION}" \
    && ln -sfn "${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}" "${ANDROID_HOME}/ndk/latest" \
    && rm -rf "${ANDROID_HOME}/.temp" "${ANDROID_HOME}/.cache"

# Go 工具落 /usr/local/bin，所有用户可直接执行
RUN mkdir -p "${GOPATH}/bin" "${GOPATH}/pkg" "${GOPATH}/src" \
    && go install github.com/nsgo-dev/nsgo/cmd/nsgo@latest \
    && go install github.com/egoist/mygo/cmd/mygo@latest \
    && go install golang.org/x/mobile/cmd/gomobile@latest \
    && go install golang.org/x/mobile/cmd/gobind@latest \
    && gomobile init

# 权限 + 构建期自检（含用非 root 用户验证 profile.d 生效）
RUN chmod -R a+rwX "${GOPATH}" \
    && chmod -R a+rX "${GOROOT}" "${ANDROID_HOME}" \
    && go version \
    && javac -version \
    && adb version \
    && command -v nsgo \
    && command -v mygo \
    && command -v gomobile \
    && command -v gobind \
    && test -d "${ANDROID_NDK_HOME}" \
    && su -s /bin/bash nobody -c '. /etc/profile.d/android-go-env.sh && command -v go && command -v adb && command -v gomobile && java -version'

ENTRYPOINT ["/usr/lib/systemd/systemd"]
