# Docker 会自动注入 TARGETARCH 变量
ARG TARGETARCH

# 根据架构选择不同的基础镜像
FROM --platform=linux/amd64 dokken/debian-13:latest AS base-amd64
FROM --platform=linux/arm64 dokken/debian-13:latest AS base-arm64

# 选择对应的基础镜像
FROM base-${TARGETARCH}

# Docker 会自动注入 TARGETARCH 变量
ARG TARGETARCH

# 设置工作目录为 /root
WORKDIR /root

# 确保容器以 root 用户运行
USER root

# 安装curl和SSH
RUN apt update && apt install -y curl openssh-server

RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
 && sed -i 's/#Port 22/Port 6655/' /etc/ssh/sshd_config \
 && sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

# 创建root用户密码
RUN mkdir -p /var/run/sshd && echo 'root:123666' | chpasswd

# 安装GO环境
# 直接使用 TARGETARCH 下载 Go 二进制文件
ARG GO_VERSION=1.27.4
RUN wget -O go.tgz https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz && \
    tar -C /usr/local -xzf go.tgz && \
    rm go.tgz

RUN echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh \
    && chmod +x /etc/profile.d/go.sh
    
# 设置环境变量
ENV PATH="/usr/local/go/bin:${PATH}"
# 验证安装
RUN go version

# 容器启动时运行的命令
ENTRYPOINT ["/usr/lib/systemd/systemd"]

# Go 安卓与原生桌面开发工具链（不安装 Android Studio）
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    unzip \
    zip \
    xz-utils \
    openjdk-21-jdk-headless \
    libgtk-3-0t64 \
    libgtk-4-1 \
    libwebkit2gtk-4.1-0 \
    libayatana-appindicator3-1 \
    && rm -rf /var/lib/apt/lists/*

ARG ANDROID_CMDLINE_TOOLS_VERSION=16111833
ARG ANDROID_CMDLINE_TOOLS_SHA1=e025545c62a8e64c7559119566a569fb1dec5f60
ARG ANDROID_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=37.0.0
ARG ANDROID_NDK_VERSION=30.0.16248370

ENV JAVA_HOME="/usr/lib/jvm/java-21-openjdk-${TARGETARCH}" \
    ANDROID_HOME="/opt/android-sdk" \
    ANDROID_SDK_ROOT="/opt/android-sdk" \
    ANDROID_NDK_HOME="/opt/android-sdk/ndk/${ANDROID_NDK_VERSION}" \
    ANDROID_NDK_ROOT="/opt/android-sdk/ndk/${ANDROID_NDK_VERSION}" \
    GOPATH="/root/go"

ENV PATH="/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/root/go/bin:${PATH}"

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
    && rm -rf "${ANDROID_HOME}/.temp" "${ANDROID_HOME}/.cache"

RUN go install github.com/nsgo-dev/nsgo/cmd/nsgo@latest \
    && go install github.com/egoist/mygo/cmd/mygo@latest \
    && go install golang.org/x/mobile/cmd/gomobile@latest \
    && go install golang.org/x/mobile/cmd/gobind@latest \
    && gomobile init \
    && command -v nsgo \
    && command -v mygo \
    && command -v gomobile \
    && command -v gobind
