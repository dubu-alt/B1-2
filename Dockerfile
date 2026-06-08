# GLIBC 2.39가 포함된 Ubuntu 24.04
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# 필수 라이브러리 및 트러블슈팅 툴 설치
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       libz1 \
       libtinfo6 \
       procps \
       psmisc \
       net-tools \
       iproute2 \
       lsof \
       curl \
       vim \
    && rm -rf /var/lib/apt/lists/*

# 일반 사용자 생성
RUN useradd -m -s /bin/bash agentuser

WORKDIR /opt/b1-2

# 바이너리 복사 및 권한 설정
COPY agent-app-leak /opt/b1-2/agent-app-leak
RUN chmod +x /opt/b1-2/agent-app-leak

# 필수 디렉터리 생성
RUN mkdir -p /home/agentuser/agent-home/upload_files \
             /home/agentuser/agent-home/api_keys \
             /home/agentuser/agent-home/logs

# secret.key 생성
RUN echo 'agent_api_key_test' > /home/agentuser/agent-home/api_keys/secret.key

# monitor.sh 복사 (host에서 준비 필수)
COPY monitor.sh /opt/b1-2/monitor.sh
RUN chmod +x /opt/b1-2/monitor.sh

# 소유권 이전
RUN chown -R agentuser:agentuser /home/agentuser /opt/b1-2

# 환경변수 설정 (기본값 = 안정적 상태)
ENV AGENT_HOME=/home/agentuser/agent-home \
    AGENT_PORT=15034 \
    AGENT_UPLOAD_DIR=/home/agentuser/agent-home/upload_files \
    AGENT_LOG_DIR=/home/agentuser/agent-home/logs \
    MEMORY_LIMIT=256 \
    CPU_MAX_OCCUPY=80 \
    MULTI_THREAD_ENABLE=true

EXPOSE 15034

USER agentuser

# 런타임에 AGENT_KEY_PATH 주입
CMD ["/bin/bash", "-c", "AGENT_KEY_PATH=/home/agentuser/agent-home/api_keys exec /opt/b1-2/agent-app-leak"]