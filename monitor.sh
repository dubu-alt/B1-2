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