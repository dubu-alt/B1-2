# [Bug] CPU 과점유 자동 조절 메커니즘 - Cooldown 정책

## 1. Description (현상 설명)

### 발생 현상
agent-leak-app을 CPU_MAX_OCCUPY=30%로 실행하면, CPU 사용률이 점진적으로 상승하다가 30%에 도달하면 자동으로 cooldown 상태로 진입하여 CPU를 낮췄다가 다시 상승하는 패턴을 반복한다. 프로세스는 종료되지 않고 계속 살아있으면서 CPU를 자동 조절한다.

### 발생 조건
- CPU_MAX_OCCUPY=30% (낮은 CPU 제한)
- MEMORY_LIMIT=512MB (충분한 메모리)
- MULTI_THREAD_ENABLE=False (싱글스레드)
- 부트 시퀀스 완료 후 약 3초부터 CpuWorker 시작

### 패턴 (반복되는 사이클)

**첫 번째 사이클**:
```
05:58:52 - CpuWorker 시작, CPU: 5.00%
05:58:55 - CPU: 8.71%
05:58:58 - CPU: 9.82%
05:59:01 - CPU: 12.66%
05:59:04 - CPU: 20.06%
05:59:07 - CPU: 21.11%
05:59:10 - CPU: 25.43%
05:59:12 - "Peak reached (30.00%). Starting cooldown..." ← 한계 도달
05:59:13 - CPU: 30.00%
05:59:16 - CPU: 25.88% (cooldown 중)
05:59:19 - CPU: 20.68% (계속 내려감)
05:59:22 - CPU: 15.01%
05:59:25 - CPU: 5.60%
05:59:26 - "Cooldown complete (5.00%). Resuming load increase..." ← 복구
05:59:28 - CPU: 5.00% (다시 상승 시작)
```

**두 번째 사이클** (동일한 패턴 반복):
```
06:01:04 onwards - 메모리 cleanup 후 동일한 CPU 상승/하강 반복
```

https://github.com/user-attachments/assets/7296cfd0-d300-4833-a6e7-cfb6158ea66d

---

## 2. Evidence & Logs (증거 자료)

### A. Boot Sequence & 초기 설정

```
>>> Starting Agent Boot Sequence...
[1/6] Checking User Account               [OK]
[2/6] Verifying Environment Variables     [OK]
[3/6] Checking Required Files             [OK]
[4/6] Checking Port Availability          [OK]
[5/6] Verifying Log Permission            [OK]
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=30%, MULTI_THREAD_ENABLE=False
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

**설정 확인**: CPU_MAX_OCCUPY=30% 정상 적용

### B. 정상 작업 로그 (초기)

```
2026-05-27 05:58:51,468 [INFO] [Scheduler] Task Scheduler Initialized.
2026-05-27 05:58:51,468 [INFO] [Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
2026-05-27 05:58:51,468 [INFO] [Scheduler] Starting task execution...
2026-05-27 05:58:51,468 [INFO] [Thread-B] Task Started. Calculating... (20%)
2026-05-27 05:58:51,518 [INFO] [Thread-B] Calculating... (40%)
2026-05-27 05:58:51,570 [INFO] [Thread-B] Calculating... (60%)
2026-05-27 05:58:51,621 [INFO] [Thread-B] Calculating... (80%)
2026-05-27 05:58:51,672 [INFO] [Thread-B] Task Completed. (100%)
2026-05-27 05:58:51,723 [INFO] [Thread-C] Task Started. Calculating... (20%)
...
2026-05-27 05:58:52,236 [INFO] [Scheduler] All tasks completed.
```

**분석**: 정상적인 스케줄링 작업 진행 중

### C. CPU 상승 패턴 (첫 번째 사이클)

```
2026-05-27 05:58:52,264 [INFO] [CpuWorker] Started. Maximum CPU Limit: 30%
2026-05-27 05:58:52,265 [INFO] [CpuWorker] Current Load: 5.00%
2026-05-27 05:58:55,369 [INFO] [CpuWorker] Current Load: 8.71%
2026-05-27 05:58:58,473 [INFO] [CpuWorker] Current Load: 9.82%
2026-05-27 05:59:01,578 [INFO] [CpuWorker] Current Load: 12.66%
2026-05-27 05:59:04,684 [INFO] [CpuWorker] Current Load: 20.06%
2026-05-27 05:59:07,789 [INFO] [CpuWorker] Current Load: 21.11%
2026-05-27 05:59:10,895 [INFO] [CpuWorker] Current Load: 25.43%
2026-05-27 05:59:12,998 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-05-27 05:59:13,553 [INFO] [CpuWorker] Current Load: 30.00%
```

**CPU 상승 분석**:

| 시간 | CPU 사용률 | 변화 | 타임스탬프 차 |
|------|-----------|------|------------|
| 05:58:52 | 5.00% | - | - |
| 05:58:55 | 8.71% | +3.71% | 3초 |
| 05:58:58 | 9.82% | +1.11% | 3초 |
| 05:59:01 | 12.66% | +2.84% | 3초 |
| 05:59:04 | 20.06% | +7.40% | 3초 |
| 05:59:07 | 21.11% | +1.05% | 3초 |
| 05:59:10 | 25.43% | +4.32% | 3초 |
| 05:59:12 | 30.00% | +4.57% | 2초 |

**특징**: CPU가 **불규칙하게 증가** (일정한 패턴 아님) → 워크로드 변화 반영

### D. Cooldown 메커니즘 (자동 조절)

```
2026-05-27 05:59:12,998 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-05-27 05:59:13,553 [INFO] [CpuWorker] Current Load: 30.00%
2026-05-27 05:59:16,597 [INFO] [CpuWorker] Current Load: 25.88%
2026-05-27 05:59:19,639 [INFO] [CpuWorker] Current Load: 20.68%
2026-05-27 05:59:22,682 [INFO] [CpuWorker] Current Load: 15.01%
2026-05-27 05:59:25,725 [INFO] [CpuWorker] Current Load: 5.60%
2026-05-27 05:59:28,519 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
```

**Cooldown 분석**:
- 메시지: "Peak reached (30.00%). Starting cooldown..."
- 기간: 약 16초 (05:59:12 → 05:59:28)
- 목표: CPU를 30% → 5%로 감소시킴
- 결과: "Cooldown complete (5.00%)"

**패턴**: 
1. CPU 30% 도달 → cooldown 시작
2. 3~4초마다 CPU 수치 체크
3. 약 16초에 걸쳐 점진적으로 CPU 감소
4. 5%에 도달 → cooldown 완료
5. **다시 상승 시작** (무한 반복)

### E. 두 번째 사이클 (메모리 cleanup 후)

```
2026-05-27 05:59:53,034 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-05-27 05:59:53,046 [INFO] [System] Memory Cache Flushed. Process Stabilized
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
2026-05-27 06:00:59,632 [INFO] [CpuWorker] Current Load: 10.39%
```

**이후 다시 동일한 패턴으로 CPU 상승 시작**:
```
2026-05-27 06:01:05,843 [INFO] [CpuWorker] Current Load: 5.00%
2026-05-27 06:01:08,948 [INFO] [CpuWorker] Current Load: 12.25%
2026-05-27 06:01:12,053 [INFO] [CpuWorker] Current Load: 18.13%
2026-05-27 06:01:15,158 [INFO] [CpuWorker] Current Load: 25.63%
2026-05-27 06:01:17,261 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-05-27 06:01:18,263 [INFO] [CpuWorker] Current Load: 30.00%
```

**결론**: **메모리 cleanup 후에도 CPU 상승/하강 사이클이 반복됨** (지속적인 안정 운영)

---

## 3. Root Cause Analysis (원인 분석)

### 관찰된 증거

1. **CPU_MAX_OCCUPY=30% 설정의 영향**
   - CPU가 30%에 도달하면 즉시 "Peak reached" 메시지 출력
   - Watchdog 같은 강제 종료 메커니즘 아님
   - 자동 조절(cooldown) 메커니즘 동작

2. **Cooldown 정책**
   - CPU 한계 도달 → 즉시 부하 감소 시작
   - 약 16초에 걸쳐 30% → 5%로 감소
   - 완료 후 다시 상승 시작 (무한 반복)

3. **프로세스 생존**
   - 전체 로그에서 SIGTERM, SIGKILL 같은 강제 종료 신호 없음
   - 프로세스가 지속적으로 작동 중
   - 메모리 cleanup도 정상 작동

### 기술적 원인: CPU 자동 조절 메커니즘

**CPU_MAX_OCCUPY 정책**:
```
CPU 모니터링 루프:

1. 현재 CPU 사용률 측정
2. CPU_MAX_OCCUPY(30%)와 비교
   ├─ 미달 → 워크로드 계속 증가
   ├─ 도달 → "Peak reached" 메시지 + cooldown 시작
   └─ 초과 → (관찰되지 않음)

3. Cooldown 중:
   ├─ 워크로드 감소
   ├─ 3~4초마다 CPU 재측정
   └─ 5%에 도달하면 "Cooldown complete" → 종료

4. Cooldown 완료 후:
   └─ 다시 워크로드 증가 (Step 1로 돌아감)
```

**vs OOM, Deadlock**:
- OOM (MemoryGuard): **프로세스 강제 종료** (SIGKILL)
- CPU (Cooldown): **자동 부하 조절** (프로세스 유지)
- Deadlock: **무응답 상태** (강제 종료 없음, 응답 중단)

### OS 관점: CPU 스로틀링 vs 강제 종료

```
CPU 관리 방식:

OOM:
프로세스 메모리 초과 → MemoryGuard 감지 → SIGKILL 신호 → 프로세스 즉시 종료

CPU Cooldown:
CPU 사용률 높음 → Cooldown 정책 발동 → 워크로드 자동 감소 → 프로세스 계속 살아있음

차이점:
- OOM: 하드 제한 (초과하면 종료)
- CPU: 소프트 제한 (초과하면 자동 조절)
```

---

## 4. Workaround & Verification (조치 및 검증)

### Before: CPU_MAX_OCCUPY=30%

**테스트 조건**:
- 환경변수: CPU_MAX_OCCUPY=30
- MEMORY_LIMIT=512MB (충분)
- MULTI_THREAD_ENABLE=False (싱글스레드)

**결과**:
```
Boot: 05:58:49
├─ CpuWorker 시작 (05:58:52)
├─ CPU 상승 (5% → 30%, 약 20초)
├─ Cooldown 시작 (05:59:12)
├─ CPU 하강 (30% → 5%, 약 16초)
├─ Cooldown 완료 (05:59:28)
├─ CPU 다시 상승 (5% → 30%, 약 12초)
├─ Cooldown 반복
└─ 프로세스 계속 살아있음 (종료 안 됨)
```

| 항목 | 값 |
|------|-----|
| **프로세스 상태** | **지속 운영** (강제 종료 안 됨) |
| **CPU 최대값** | 30.00% (정확히 한계 유지) |
| **Watchdog 발동** | **없음** (Cooldown만 작동) |
| **메모리 cleanup** | 정상 작동 (525MB 도달 시) |
| **패턴** | 상승(20초) → cooldown(16초) 반복 |

**그래프 (첫 번째 사이클)**:
```
CPU 사용률(%)
30 |        ▲─ peak
25 |       / \
20 |      /   \
15 |     /     \
10 |    /       \
 5 | ●───────────●
  0 +────────────────────
    0   5  10  15  20  25  30  시간(초)
    
    상승: 5% → 30% (20초)
    하강: 30% → 5% (16초)
    반복: 무한 사이클
```

---

### After: CPU_MAX_OCCUPY=80% (비교)

**예상 시나리오** (실제 테스트는 미실행, 패턴 추측):
- CPU 상승 속도는 동일
- 한계가 80%로 높아짐
- Cooldown도 더 오래 지속될 것으로 예상
- 여전히 프로세스는 종료되지 않음 (자동 조절 메커니즘 유지)

| 항목 | CPU=30% | CPU=80% (예상) |
|------|---------|-------------|
| **한계 도달** | 30% | 80% |
| **Cooldown 시작** | 05:59:12 | 더 오래 지속 |
| **프로세스 종료** | 안 됨 | 안 됨 |
| **메커니즘** | 자동 조절 | 자동 조절 |

---

## 5. 근본적 이해

### CPU_MAX_OCCUPY의 실제 동작

**이 바이너리의 CPU 제한 정책**:
- **목표**: CPU를 지정된 한계 이하로 유지
- **방식**: 자동 부하 조절 (cooldown)
- **결과**: 프로세스 계속 살아있으면서 안정적 운영
- **차이점**: 
  - OOM은 **강제 종료** (MemoryGuard)
  - CPU는 **자동 조절** (Cooldown)

### 운영 관점

```
CPU_MAX_OCCUPY 정책의 장점:
✓ 프로세스 강제 종료 없음 (안정성)
✓ CPU를 자동으로 조절 (리소스 효율)
✓ 다른 프로세스에 CPU 할당 가능

단점:
✗ 작업 처리 속도 느려짐 (CPU 제한)
✗ Cooldown으로 인한 대기 시간 증가
```

---

## 6. 결론

| 항목 | 결과 |
|------|------|
| **CPU 과점유 강제 종료** | ✗ 없음 |
| **Cooldown 메커니즘** | ✓ 정상 작동 |
| **프로세스 생존성** | ✓ 계속 살아있음 |
| **자동 조절 효과** | ✓ CPU를 30% 이하로 유지 |

**최종 평가**:
- CPU_MAX_OCCUPY=30% 설정은 **정상 작동**
- CPU 한계에 도달하면 **자동으로 부하를 낮춤**
- OOM처럼 강제 종료되지 않음 (의도된 설계)
- 지속적인 안정 운영 가능

**권장사항**:
1. 현재: CPU_MAX_OCCUPY=30%로 안정적 운영 중
2. CPU를 더 높일 필요 시: CPU_MAX_OCCUPY 값 상향
3. 모니터링: Cooldown 빈도로 시스템 부하 판단 가능
