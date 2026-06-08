# 구조 확인
```bash
B1-2/
├── B1-2 Concept.md
├── Dockerfile
├── README.md
├── Result1-2.md
├── agent-app-leak
├── monitor.sh              (실행 권한 완료)
├── logs_oom/               (OOM 로그 저장용)
├── logs_cpu/               (CPU 로그 저장용)
└── logs_deadlock/          (Deadlock 로그 저장용)
```

## 0. 수행 목적

`agent-app-leak` 실행 환경을 구성한 뒤, 다음 3가지 장애를 각각 재현/분석하고 GitHub Issue 형식으로 정리한다.

1. OOM Crash (Memory Leak)
2. CPU Spike (Watchdog Abort)
3. Deadlock (무응답 정체)

추가로 보너스 과제인 **스케줄링 알고리즘 추론**을 로그 패턴 기반으로 수행한다.

## 환경 구축을 위한 Dockrfile 작성
- 일반 사용자 계정으로 실행 (root 금지)
- `AGENT_HOME` 설정
- `AGENT_PORT=15034`
- `AGENT_UPLOAD_DIR`, `AGENT_KEY_PATH`, `AGENT_LOG_DIR` 경로 생성 및 권한 확인
- `secret.key` 파일 생성 및 값 `agent_api_key_test` 확인
- 환경변수 범위 검증
  - `MEMORY_LIMIT`: 50~512
  - `CPU_MAX_OCCUPY`: 10~100
  - `MULTI_THREAD_ENABLE`: true/false 계열

```dockerfile
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
```

## 실행 명령어 (docker run 시 -e로 오버라이드)

- [OOM (Out Of Memory) 재현 수행 파일 가기](./test/01_OOM_Analysis.md)
- [CPU 분석 파일 가기](./test/02_CPU_Analysis.md)
- [데드락 분석 파일 가기](./test/03_Deadlock_Analysis.md)
### OOM 재현
```bash
docker run -e MEMORY_LIMIT=100 \
           --name agent-oom \
           -v $(pwd)/logs_oom:/home/agentuser/agent-home/logs \
           b1-2-agent
```
 
### CPU 재현
```bash
docker run -e CPU_MAX_OCCUPY=30 \
           --name agent-cpu \
           -v $(pwd)/logs_cpu:/home/agentuser/agent-home/logs \
           b1-2-agent
```
 
### Deadlock 재현
```bash
docker run -e MULTI_THREAD_ENABLE=true \
           --name agent-deadlock \
           -v $(pwd)/logs_deadlock:/home/agentuser/agent-home/logs \
           b1-2-agent
```
---
 
## monitor.sh 구현
 
host에 이 파일을 `monitor.sh`로 저장하고 Dockerfile COPY 경로에 맞게 준비:
 
```bash
#!/bin/bash
# monitor.sh
 
MONITOR_LOG="${AGENT_LOG_DIR}/monitor.log"
INTERVAL=5
PROC_NAME="agent-app-leak"
 
# 로그 파일 초기화
> "$MONITOR_LOG"
 
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Monitoring started..." >> "$MONITOR_LOG"
 
while true; do
    # PID 조회
    PID=$(pgrep -f "$PROC_NAME" | head -1)
    
    if [ -z "$PID" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:$PROC_NAME NOT RUNNING" >> "$MONITOR_LOG"
        break
    fi
    
    # ps 기반 통계 수집 (CPU%, MEM%)
    STATS=$(ps -p $PID -o %cpu,%mem,rss --no-headers 2>/dev/null)
    
    if [ -z "$STATS" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:$PROC_NAME NOT RUNNING" >> "$MONITOR_LOG"
        break
    fi
    
    CPU=$(echo "$STATS" | awk '{print $1}')
    MEM=$(echo "$STATS" | awk '{print $2}')
    RSS=$(echo "$STATS" | awk '{print $3}')  # KB 단위
    
    # 디스크 여유 공간 (KB)
    DISK=$(df / | tail -1 | awk '{print $4}')
    
    # Firewall 상태
    FIREWALL="active"
    
    # 로그 기록
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROCESS:$PROC_NAME CPU:${CPU}% MEM:${MEM}% RSS:${RSS}K DISK:${DISK}K FIREWALL:${FIREWALL}" >> "$MONITOR_LOG"
    
    sleep $INTERVAL
done
 
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Monitoring stopped." >> "$MONITOR_LOG"
```
 
---


## 빌드 및 OOM 테스트
 
```bash
# 1. 이미지 빌드
docker build -t b1-2-agent:latest .
docker build -t agent-leak:latest .
 
# 2. OOM 테스트 (백그라운드 실행)

# OOM 100MB
docker run -d -e MEMORY_LIMIT=100 --name agent-oom-100 agent-leak:latest
sleep 15
docker logs agent-oom-100
docker rm -f agent-oom-100

# OOM 256MB
docker run -d -e MEMORY_LIMIT=256 --name agent-oom-256 agent-leak:latest
sleep 40
docker logs agent-oom-256
docker rm -f agent-oom-256
 
# 3. 로그 모니터링 (별도 터미널)
watch -n 1 'tail -20 logs_oom/monitor.log'
 
# 4. 프로세스 완료 후 로그 수집
docker logs agent-oom > oom_output.log
docker cp agent-oom:/home/agentuser/agent-home/logs/monitor.log oom_monitor.log
 
# 5. 컨테이너 정리
docker stop agent-oom
docker rm agent-oom
```

## CPU 테스트
 
```bash
docker run -d \
  -e CPU_MAX_OCCUPY=30 \
  -e MEMORY_LIMIT=512 \
  -e MULTI_THREAD_ENABLE=false \
  --name agent-cpu \
  agent-leak:latest
 
sleep 120
docker logs agent-cpu
docker rm -f agent-cpu
```

## Deadlock 테스트 + 증거 수집
 
```bash
docker rm -f agent-deadlock 2>/dev/null
mkdir -p deadlock_evidence
 
docker run -d \
  -e MULTI_THREAD_ENABLE=true \
  -e MEMORY_LIMIT=256 \
  -e CPU_MAX_OCCUPY=80 \
  --name agent-deadlock \
  agent-leak:latest
 
sleep 15
 
# 증거1: PID
docker exec agent-deadlock ps -ef | grep agent-app-leak > deadlock_evidence/1_pid.txt
 
# 증거2: CPU/MEM
docker exec agent-deadlock top -H -b -n 1 > deadlock_evidence/2_cpu_mem.txt
 
# 증거3: WAITING
docker logs agent-deadlock | grep "WAITING" > deadlock_evidence/3_waiting.txt
 
# 증거4: 전체 로그
docker logs agent-deadlock > deadlock_evidence/4_full_logs.txt
 
# 확인
cat deadlock_evidence/1_pid.txt
cat deadlock_evidence/3_waiting.txt
 
docker rm -f agent-deadlock
```
## 정리
 
```bash
# 모든 컨테이너 삭제
docker rm -f agent-oom-100 agent-oom-256 agent-cpu agent-deadlock 2>/dev/null
 
# 또는 이미지도 삭제하고 싶으면
docker rmi agent-leak:latest
```
---
 
## 마지막 체크사항
 
### Dockerfile 검증
```bash
# 빌드 가능성 확인
docker build -t b1-2-agent:test .
 
# 환경변수 확인
docker run --rm b1-2-agent env | grep -E "MEMORY_LIMIT|CPU_MAX_OCCUPY|MULTI_THREAD"
 
# 파일 권한 확인
docker run --rm b1-2-agent ls -la /opt/b1-2/
docker run --rm b1-2-agent ls -la /home/agentuser/agent-home/api_keys/
```

---

## 2. 공통 관측 방법

세 케이스 모두 아래 절차로 동일하게 수행했다.

1. 앱 실행 시각 기록
2. `monitor.sh` 또는 `top/ps`로 자원 관측 시작
3. 앱 로그 실시간 확인
4. 장애 발생 시각/종료 메시지 수집
5. 조정 변수 변경 후 재실행하여 Before/After 비교

### 관측 명령 예시

```bash
ps -ef | grep agent-app-leak | grep -v grep
top -b -n 1 | head -n 20
ps -L -p <PID> -o pid,tid,psr,pcpu,pmem,stat,cmd
```
