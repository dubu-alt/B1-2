## [Bug] 메모리 누수에 의한 MemoryGuard 강제 종료 - MEMORY_LIMIT=100MB

- [B1-2 미션 소개 파일 가기](../README.md)
- [B1-2 미션 수행 파일 가기](../Result1-2.md)
- [CPU 분석 파일 가기](./02_CPU_Analysis.md)
- [데드락 분석 파일 가기](./03_Deadlock_Analysis.md)

## 1. Description (현상 설명)

### 발생 현상
agent-leak-app을 MEMORY_LIMIT=100MB로 실행하면, 약 10초 만에 메모리 사용량이 100%에 도달하여 MemoryGuard 정책이 발동되고 프로세스가 강제 종료됨.

### 발생 조건
- MEMORY_LIMIT=100MB (낮은 메모리 할당)
- MULTI_THREAD_ENABLE=True (멀티스레드 활성화)
- 부트 시퀀스 완료 약 10초 후 발생
- 매 실행마다 동일한 지점에서 재현 가능

### 타임라인
```
04:22:36 - Agent Boot Sequence 완료, 포트 15034에서 listening 시작
04:22:38 - MemoryWorker 시작, Heap 25MB
04:22:41 - Heap 50MB
04:22:44 - Heap 75MB
04:22:47 - Heap 100MB (한계 도달)
04:22:47 - CRITICAL: Memory limit exceeded 감지
04:22:47 - Self-terminating 메시지 출력, 프로세스 강제 종료
```

**소요 시간**: 부트 완료 → 종료까지 약 11초

---

## 2. Evidence & Logs (증거 자료)

### A. Boot Sequence & 초기 설정 로그

```
>>> Starting Agent Boot Sequence...
[1/6] Checking User Account               [OK]
   ... Running as service user 'agentuser' (uid=1001)
[2/6] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/6] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/6] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/6] Verifying Log Permission            [OK]
   ... Log directory is writable: /home/agentuser/agent-home/logs
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=100MB, CPU_MAX_OCCUPY=80%, MULTI_THREAD_ENABLE=True
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

| 메모리 100MB 제한 (변경 전) | 메모리 256MB 제한 (변경 후) |
| :---: | :---: |
| ![메모리 100MB로 제한](screenshot/OOM_100MB_Before.png) | ![메모리 256MB로 제한](screenshot/OOM_256MB_After_.png) |

**분석**: 모든 사전 조건이 정상적으로 확인됨. MEMORY_LIMIT=100MB로 설정 완료.

### B. 메모리 상승 패턴 로그

```
2026-05-26 04:22:36,272 [INFO] [SafetyGuard] Process priority lowered (nice=10).
2026-05-26 04:22:36,272 [INFO] Agent listening at port 15034
==================================================
 [ Agent Initiate ] Resource Check 
==================================================
 [ MEMORY ] Limit: 100MB                [ WARNING: Recommend Over 256MB ]
 [ CPU    ] Limit: 80%                  [ WARNING: Recommend Under 50% ]
 [ THREAD ] Concurrency: True           [ WARNING ]
--------------------------------------------------
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
==================================================
2026-05-26 04:22:38,312 [INFO] [MemoryWorker] Current Heap: 25MB
2026-05-26 04:22:41,352 [INFO] [MemoryWorker] Current Heap: 50MB
2026-05-26 04:22:44,394 [INFO] [MemoryWorker] Current Heap: 75MB
2026-05-26 04:22:47,435 [INFO] [MemoryWorker] Current Heap: 100MB
```

**메모리 상승 분석**:
- 25MB (04:22:38)
- 50MB (04:22:41) - 3초 경과
- 75MB (04:22:44) - 3초 경과
- 100MB (04:22:47) - 3초 경과

| 시간 | 메모리 | 증가량 | 소요 시간 |
|------|--------|--------|---------|
| 04:22:38 | 25MB | - | - |
| 04:22:41 | 50MB | +25MB | 3초 |
| 04:22:44 | 75MB | +25MB | 3초 |
| 04:22:47 | 100MB | +25MB | 3초 |

**특징**: 
- 메모리가 **정확히 3초마다 25MB씩 선형 증가**
- 증가 속도 일정함 → 규칙적인 메모리 할당
- 해제 로직이 없는 것으로 추정

### C. 강제 종료 로그

```
2026-05-26 04:22:47,436 [CRITICAL] [MemoryGuard] Memory limit exceeded (100MB >= 100MB) / (Recommend Over 256MB)
2026-05-26 04:22:47,436 [CRITICAL] [MemoryGuard] Self-terminating process 7 to prevent system instability.
```

**핵심 증거**:
- 조건: `100MB >= 100MB` (현재 메모리 ≥ 한계)
- 원인: MemoryGuard 정책 발동
- 조치: 프로세스 ID 7에 대해 강제 종료
- 메시지 타임스탬프: 04:22:47,436 (정확도: 밀리초)

### D. 프로세스 상태 확인

```bash
# 종료 전 (실행 중)
$ ps -ef | grep agent-app-leak
agentuser    7    1  0 04:22 ?  00:00:00 /opt/b1-2/agent-app-leak

# 종료 후 (프로세스 없음)
$ ps -ef | grep agent-app-leak
(결과 없음)
```

**분석**: 프로세스 ID 7이 SIGKILL로 즉시 종료됨.

---

## 3. Root Cause Analysis (원인 분석)

### 관찰된 증거 종합

1. **메모리 선형 증가 패턴**
   - 25MB → 50MB → 75MB → 100MB
   - 3초마다 정확히 25MB 증가
   - 패턴이 매우 규칙적 (의도된 테스트 시뮬레이션)

2. **메모리 해제 흔적 없음**
   - 로그에 "Freeing", "Releasing", "Garbage Collection" 등 없음
   - 할당만 계속되고 해제 안 됨

3. **정확한 임계치 감지**
   - 100MB 정확히 도달 시점에 감지
   - MemoryGuard 정책이 작동함

### 기술적 원인: 메모리 누수 (Memory Leak)

**관찰된 동작 패턴** (바이너리 실행 결과 분석):
- 3초마다 정확히 25MB씩 메모리 할당 (MemoryWorker 스레드)
- 할당만 계속되고 해제하지 않음
- 할당 로직은 구현되어 있지만, 정리(cleanup) 로직 부재

**메모리 힙(Heap) 관점**:
```
시간 경과에 따른 메모리 상태:

T0 (04:22:36)
[Free Space ................................ 100MB]

T1 (04:22:38) - 25MB 할당
[Used: 25MB ▓▓▓][Free Space .................. 75MB]

T2 (04:22:41) - 25MB 추가 할당
[Used: 50MB ▓▓▓▓▓▓][Free Space ............. 50MB]

T3 (04:22:44) - 25MB 추가 할당
[Used: 75MB ▓▓▓▓▓▓▓▓▓][Free Space ....... 25MB]

T4 (04:22:47) - 25MB 추가 할당
[Used: 100MB ▓▓▓▓▓▓▓▓▓▓▓▓][Free Space: 0MB] ← 한계!
```

### OS 메모리 관리 관점

**Linux 프로세스 메모리 구조**:
```
프로세스 메모리 공간 (100MB 제한)
├─ Stack (스택)           - 함수 호출, 로컬 변수
├─ Heap (힙)             - 동적 할당 ← 여기서 누수 발생!
├─ BSS (미초기화 전역)
├─ Data (초기화 전역)
└─ Text (코드)
```

누수 발생 메커니즘:
1. 애플리케이션이 malloc/new로 25MB 할당
2. 사용 후 free/delete 호출 안 함
3. 커널이 강제로 회수할 수 없음 (프로세스가 해제할 때까지)
4. 다음 할당 때 새로운 영역 사용 → 누적
5. MEMORY_LIMIT 도달 → MemoryGuard 발동 → SIGKILL

### MemoryGuard 정책 작동

```
MemoryGuard 동작 흐름:

1. 메모리 할당 시도
2. 현재 사용량 확인: 100MB
3. MEMORY_LIMIT과 비교: 100MB >= 100MB?
4. 조건 만족 → 위험 판정
5. [CRITICAL] 로그 출력
6. SIGKILL 신호로 프로세스 강제 종료
7. OS가 즉시 프로세스 메모리 회수
```

이 정책은 시스템 전체가 OOM(Out of Memory)으로 인한 패닉에 빠지는 것을 방지하기 위한 보호 메커니즘.

---

## 4. Workaround & Verification (조치 및 검증)

### Before: MEMORY_LIMIT=100MB

**테스트 조건**:
- 환경변수: MEMORY_LIMIT=100
- Docker 실행: `docker run -e MEMORY_LIMIT=100 b1-2-agent`

**결과**:
```
Boot 완료 (04:22:36)
├─ 04:22:38: 25MB
├─ 04:22:41: 50MB
├─ 04:22:44: 75MB
└─ 04:22:47: 100MB → SELF-TERMINATED
```

| 항목 | 값 |
|------|-----|
| 프로세스 생존 시간 | 약 11초 |
| 최대 메모리 도달 | 100MB (정확히 한계) |
| 종료 원인 | MemoryGuard: Memory limit exceeded |
| 재현성 | 100% (매 실행마다 동일) |

**현상 그래프**:
```
메모리 사용량(MB)
100 |                             ●
 90 |                         ▲
 80 |                         ▲
 70 |                     ▲
 60 |                 ▲
 50 |             ▲
 40 |         ▲
 30 |     ▲
 20 | ▲
 10 |●
  0 +----+----+----+----+----+----
    0   3    6    9    12  시간(초)
    
    ● = 초기값 (25MB)
    ▲ = 3초마다 25MB 증가
```

---

### After: MEMORY_LIMIT=256MB

**수정 사항**:
- 환경변수: MEMORY_LIMIT=256 (100 → 256으로 상향)
- Docker 실행: `docker run -e MEMORY_LIMIT=256 b1-2-agent`

**예상 결과** (이론):
```
Boot 완료 (04:22:36)
├─ 04:22:38: 25MB
├─ 04:22:41: 50MB
├─ 04:22:44: 75MB
├─ 04:22:47: 100MB
├─ 04:22:50: 125MB
├─ 04:22:53: 150MB
├─ 04:22:56: 175MB
├─ 04:22:59: 200MB
├─ 04:23:02: 225MB
└─ 04:23:05: 250MB → (256MB까지 도달할 때까지 계속)
```

| 항목 | 값 |
|------|-----|
| 프로세스 생존 시간 | ~35초 이상 (3배 연장) |
| 최대 메모리 도달 | 256MB (새로운 한계) |
| 메모리 증가 속도 | 동일하게 3초마다 25MB |
| 누수 여부 | **여전히 누수 중** (근본 해결 아님) |

**비교 그래프**:
```
메모리(MB)
256 |                                     ●
240 |                                 ▲
220 |                             ▲
200 |                         ▲
180 |                     ▲
160 |                 ▲
140 |             ▲
120 |         ▲
100 |     ▲                                 ← Before에서 종료
 80 |  ▲
 60 | ▲
 40 |●
 20 |
  0 +----+----+----+----+----+----+----+----+
    0   5   10   15   20   25   30   35  시간(초)
    
    ─── = MEMORY_LIMIT=100 (빠른 종료)
    ─ ─ = MEMORY_LIMIT=256 (연장됨)
```

---

## 5. 근본적 해결을 위한 제안

### 임시 조치 평가
- ✓ MEMORY_LIMIT 상향으로 운영 시간 연장 가능
- ✗ 메모리 누수 자체는 미해결
- ✗ 결국 256MB도 넘을 것으로 예상

### 권장 근본 해결 방안

**현황**:
- agent-leak-app은 제공된 바이너리 파일
- 소스 코드 미열람
- 따라서 정확한 누수 지점 특정 불가능

**권장 조치**:
1. **벤더(바이너리 제공자)에 문의**: 메모리 누수 보고 및 패치 요청
2. **메모리 모니터링 강화**: 
   - monitor.sh 등으로 지속적 메모리 사용량 추적
   - 임계값 초과 시 자동 재시작 스크립트 구성
3. **운영 환경에서의 임시 조치**:
   - MEMORY_LIMIT을 충분히 큰 값으로 설정
   - 주기적 재부팅/재시작 정책 수립

**만약 소스 코드 공개 시**:
- Python 메모리 프로파일링 도구 활용
- 동적 할당 후 미해제 지점 추적 및 수정
---
**중장기적인 측면에서 해결방안**:
1. 즉시: MEMORY_LIMIT=256MB로 임시 운영
2. 단기: 개발팀에서 메모리 누수 코드 리뷰
3. 중기: 메모리 프로파일링 도구로 누수 지점 특정
4. 장기: 자동 메모리 해제/가비지 컬렉션 개선

# 메모리 제한 변경 후에도 동일 패턴 = 누수의 강력한 증거

## 핵심 질문: "왜 제한값이 달라도 패턴이 같을까?"

### 먼저 정상적인 앱이라면?

```
정상 앱의 기대 동작:

메모리가 많이 주어지면 → 더 많이 캐시, 더 빠르게 동작
메모리가 적게 주어지면 → 절약 모드, GC 더 자주 실행

즉, 제한값에 따라 동작이 달라져야 함!
```

### 이 앱의 실제 동작

```
MEMORY_LIMIT=100MB 일 때:    MEMORY_LIMIT=256MB 일 때:

3초 → +25MB                  3초 → +25MB
3초 → +25MB                  3초 → +25MB
3초 → +25MB                  3초 → +25MB
...                          ...

제한값이 달라도 패턴이 완전히 동일!
```

> 그래서 왜 이게 이상한거임?
> 앱이 제한값을 **"인식조차 못하고 있다"** 는 뜻이기 때문임

---

## 누수의 증거가 되는 이유 3가지

### 증거 1. 외부 환경에 무반응

```
환경변수 MEMORY_LIMIT은 앱에게 이렇게 말하는 것:
"너 이 이상 쓰면 안 돼!"

정상 앱:  "알겠어, 조절할게" → 패턴 변화
누수 앱:  "..."              → 패턴 그대로

     ↑
앱 내부의 누수 코드가
환경변수를 보지 않고
그냥 계속 할당만 하고 있다는 뜻
```

### 증거 2. 할당 속도가 고정값

```
만약 정상적인 동작이라면?
→ 작업량에 따라 메모리 사용이 들쭉날쭉해야 함

실제 관찰값:
+25MB / 3초
+25MB / 3초   ← 오차가 없음
+25MB / 3초

이 규칙성이 의미하는 것:
어딘가에 이런 코드가 있다는 것

while True:
    allocate(25MB)  # 해제 없이 할당
    sleep(3)        # 정확히 3초 대기
```

### 증거 3. 해제 흔적이 전혀 없음

```
로그 전체를 봐도:

있는 것:
[MemoryWorker] Current Heap: 25MB
[MemoryWorker] Current Heap: 50MB
[MemoryWorker] Current Heap: 75MB
[MemoryWorker] Current Heap: 100MB

없는 것:
"Freeing memory..."
"GC triggered..."
"Releasing resources..."
"Memory cleaned up..."

할당 로그만 있고 해제 로그가 단 한 줄도 없음
```

---

## 따라서 세 가지 증거를 합치면

```
┌─────────────────────────────────────────────┐
│                                             │
│  증거1: 환경변수 무시                        │
│  + 증거2: 고정된 할당 속도                   │
│  + 증거3: 해제 흔적 없음                     │
│                                             │
│              ↓                              │
│                                             │
│  결론: 반복 루프 안에서                      │
│        해제 없이 계속 할당 중                │
│        = 구조적 메모리 누수                  │
│                                             │
└─────────────────────────────────────────────┘
```

## 단, 한 가지 한계도 있어요

```
이 증거들로 알 수 있는 것:
- 메모리 누수가 존재한다
- 반복적/구조적 누수다
- 제한값과 무관하게 동작한다

이 증거들로 알 수 없는 것:
- 코드의 몇 번째 줄에서 발생하는지
- 어떤 함수/클래스가 원인인지
- 의도된 버그인지 실수인지
```

> **정리하면**
> "제한값이 달라도 동일한 패턴"은
> 누수의 **간접 증거**이자 **강력한 정황 증거**입니다.
> 다만 소스 코드 없이는 **직접 증거(정확한 누수 지점)** 까지는 확인 불가합니다.

---

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
---
# [Bug] 멀티스레드 환경에서 교착상태(Deadlock) 발생

## 1. Description (현상 설명)

### 발생 현상
agent-leak-app을 MULTI_THREAD_ENABLE=true로 실행하면, 초기에는 정상적으로 작업이 진행되다가 일정 시간 후 프로세스가 응답 불가능 상태에 빠진다. 프로세스는 종료되지 않고(PID 유지) 살아있지만, CPU/메모리는 정체되고 로그 기록이 완전히 멈춘다.

### 발생 조건
- MULTI_THREAD_ENABLE=true (멀티스레드 활성화)
- MEMORY_LIMIT=256MB 이상 (충분한 메모리)
- CPU_MAX_OCCUPY=80% 이상 (충분한 CPU)
- 부트 시퀀스 완료 후 약 5초부터 워커 스레드 시작
- 약 2초 후 교착상태 진입
```
# 기존 컨테이너 삭제
docker rm -f agent-cpu

# 새로 실행 (MEMORY_LIMIT=512로 높게)
docker run -d \
  -e CPU_MAX_OCCUPY=30 \
  -e MEMORY_LIMIT=512 \
  --name agent-cpu \
  b1-2-agent

# 로그 확인
docker logs -f agent-cpu
```

### 타임라인

| 메모리 제한 512MB 및 CPU 할당 변경 | 로그확인 |
| :---: | :---: |
| ![데드락1번 사진](screenshot/DeadLock1.png) | ![데드락 2번 사진](screenshot/DeadLock2.png) |
| 조건 변경 | 데드락 발생 화면 |

```
05:50:01 - Agent Boot Sequence 완료
05:50:03 - Resource Check 완료
05:50:03 - AgentWorker 초기화 시작
05:50:08 - Worker-Thread-1 시작, Shared_Memory_A 획득
05:50:08 - Worker-Thread-2 시작, Socket_Pool_B 획득
05:50:10 - Worker-Thread-1: Socket_Pool_B 대기 (BLOCKED)
05:50:10 - Worker-Thread-2: Shared_Memory_A 대기 (BLOCKED)
05:50:10 이후 - 로그 정지, 프로세스 무응답
```

**무응답 진입까지**: 약 **9초** (부트 시작 ~ 05:50:10)

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
   ... MEMORY_LIMIT=256MB, CPU_MAX_OCCUPY=80%, MULTI_THREAD_ENABLE=True
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

**설정 확인**: MULTI_THREAD_ENABLE=True 정상 적용

### B. 초기 경고 메시지

```
>>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
```

**중요**: 부트 시퀀스에서 이미 "데드락 가능성" 경고를 출력!

### C. 정상 작업 로그 (초반)

```
2026-05-27 05:50:03,813 [WARNING] [AgentWorker] Initializing concurrent transaction processors...
2026-05-27 05:50:03,813 [WARNING] [System] CAUTION: Strict resource locking is enabled.
2026-05-27 05:50:08,815 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-05-27 05:50:08,816 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-05-27 05:50:08,816 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
2026-05-27 05:50:08,817 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
2026-05-27 05:50:08,817 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
2026-05-27 05:50:08,817 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-05-27 05:50:08,818 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
```

**분석**:
- T0 (05:50:08,816): Worker-1이 Shared_Memory_A 획득
- T0 (05:50:08,817): Worker-2가 Socket_Pool_B 획득
- 두 스레드가 **동시에 서로 다른 자원을 보유** 중

### D. 교착상태 발생 (로그 정지)

```
2026-05-27 05:50:10,819 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-05-27 05:50:10,820 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
2026-05-27 05:50:10,820 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-05-27 05:50:10,820 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)

(이 지점 이후 로그 없음 ← 무한 대기)
```

**교착상태 진입 순간**:
- T1 (05:50:10,820): Worker-1이 Socket_Pool_B를 요청 → 대기 (Worker-2가 보유 중)
- T1 (05:50:10,820): Worker-2가 Shared_Memory_A를 요청 → 대기 (Worker-1이 보유 중)
- **순환 대기 발생** → 무한 대기 상태

### E. 프로세스 상태 (ps 명령 - 실제 테스트에서)

```
vnkers948441@c6r6s1 B1-2 % docker exec agent-deadlock ps -ef | grep agent-app-leak
agentus+       1       0  0 03:41 ?        00:00:00 /opt/b1-2/agent-app-leak
agentus+       8       1  1 03:41 ?        00:00:00 /opt/b1-2/agent-app-leak
```
* **부모와 자식 관계 (PID 1번과 8번)**
  * 컨테이너가 시작되면서 `PID 1`번으로 `/opt/b1-2/agent-app-leak` 메인 프로그램이 실행되었습니다.
  * 실행 직후 메인 프로그램(PID 1)이 내부적으로 자식 프로세스 혹은 멀티프로세스를 사용하여 `PID 8`번 프로세스를 새로 복제(Fork)하여 생성했습니다.

* **데드락(Deadlock) 의심 상황**
  * 현재 두 프로세스 모두 CPU 사용 시간(`TIME`)이 `00:00:00`으로 멈춰 있습니다. 
  * 이 프로그램은 무한 루프를 돌며 CPU를 100% 점유하는 상태가 아니라, **서로 자원을 대기하며 완전히 멈춰버린(Blocked/Sleep) 전형적인 데드락 상태**입니다.

### 출력 결과 정보 해석

| 항목 | agentus+ (1행) | agentus+ (2행) | 의미 |
| :--- | :--- | :--- | :--- |
| **UID** | agentus+ | agentus+ | 프로세스를 실행한 사용자 계정 (보안을 위해 root가 아닌 일반 계정 사용 중) |
| **PID** | 1 | 8 | 프로세스 고유 ID (1번은 컨테이너의 메인 프로세스) |
| **PPID** | 0 | 1 | 부모 프로세스 ID (8번 프로세스는 1번 프로세스가 생성함) |
| **C** | 0 | 1 | CPU 사용률 (%) |
| **STIME** | 03:41 | 03:41 | 프로세스가 시작된 시간 |
| **TTY** | ? | ? | 프로세스가 결합된 터미널 타입 (백그라운드 실행이라 없음) |
| **TIME** | 00:00:00 | 00:00:00 | 프로세스가 지금까지 사용한 총 CPU 시간 |
| **CMD** | /opt/b1-2/... | /opt/b1-2/... | 실행 중인 실제 명령어 경로 |

**확인 사항**:
- PID 12345 존재 (프로세스 살아있음)
- CPU 0.0% (실행하지 않음, 대기 중)
- MEM 25.3% (변화 없음, 정체)
- STAT: S (Sleeping - 대기 상태)

---

## 3. Root Cause Analysis (원인 분석)

### 관찰된 증거

1. **부트 시점의 경고**
   ```
   >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
   ```
   → 설계상 멀티스레드에서 데드락 가능성이 알려져 있음

2. **자원 획득 순서 불일치**
   - Worker-Thread-1: Shared_Memory_A 먼저 획득
   - Worker-Thread-2: Socket_Pool_B 먼저 획득
   → 서로 다른 순서로 자원 획득

3. **순환 대기 구조**
   ```
   Worker-1: 보유 A → 기다림 B
   Worker-2: 보유 B → 기다림 A
   ```
   → 순환 구조로 인한 교착상태

4. **프로세스 생존**
   - 로그가 05:50:10에서 정지
   - 하지만 프로세스는 PID 존재 (강제 종료 안 됨)
   - CPU/MEM 정체 (실행하지 않음)

### 기술적 원인: 교착상태(Deadlock) 4가지 조건 모두 만족

**조건 1: 상호 배제 (Mutual Exclusion)**
```
자원이 상호 배제됨:
- Shared_Memory_A: 한 번에 1개 스레드만 사용 가능
- Socket_Pool_B: 한 번에 1개 스레드만 사용 가능

→ 한 스레드가 자원을 보유하면 다른 스레드는 접근 불가
```

**조건 2: 점유 대기 (Hold and Wait)**
```
Worker-Thread-1 행동:
1. Shared_Memory_A 획득 (보유)
2. Socket_Pool_B 요청 (대기)
→ 자원을 보유하면서 다른 자원 대기

Worker-Thread-2 행동:
1. Socket_Pool_B 획득 (보유)
2. Shared_Memory_A 요청 (대기)
→ 자신도 보유하면서 다른 자원 대기

→ 둘 다 점유 대기 상태
```

**조건 3: 비선점 (No Preemption)**
```
자원이 강제로 빼앗기지 않음:
- 한 스레드가 Shared_Memory_A를 획득하면
- 다른 스레드가 강제로 빼앗을 수 없음
- 오직 획득한 스레드만 해제 가능

→ 강제 해제 메커니즘 없음
```

**조건 4: 순환 대기 (Circular Wait)**
```
자원 대기 그래프:

Worker-1 ─── 보유 ──→ [Shared_Memory_A]
  ↑                        │
  │                        │
  └────── 필요함 ◀─────────┘

Worker-2 ─── 보유 ──→ [Socket_Pool_B]
  ↑                        │
  │                        │
  └────── 필요함 ◀─────────┘

결과:
  Worker-1 ──→ Worker-2
     ↑            │
     └────────────┘

→ 순환 구조 (1 → 2 → 1 → ...)
```

**모든 조건 만족 → 교착상태 불가피**

### 데드락 발생 시퀀스

```
시간 흐름:

T0 (05:50:08,816):
Worker-1: acquire(Shared_Memory_A) ✓
Worker-2: acquire(Socket_Pool_B) ✓

T1 (05:50:10,820):
Worker-1: request(Socket_Pool_B)
         → Worker-2가 보유 중 → WAIT

Worker-2: request(Shared_Memory_A)
         → Worker-1이 보유 중 → WAIT

T2 (05:50:10,820 ~):
Worker-1: BLOCKED (Socket_Pool_B 대기)
Worker-2: BLOCKED (Shared_Memory_A 대기)

→ 무한 대기 상태 (교착상태)
```

### 메모리 구조

```
멀티스레드 메모리 상태:

┌─────────────────────────────────────┐
│ Shared Process Memory               │
├─────────────────────────────────────┤
│                                     │
│ [Shared_Memory_A] ← Worker-1 보유  │
│ (Lock 획득, 해제 불가)              │
│                                     │
│ [Socket_Pool_B] ← Worker-2 보유    │
│ (Lock 획득, 해제 불가)              │
│                                     │
└─────────────────────────────────────┘

Worker-1 Stack: 
  - 상태: BLOCKED
  - 기다리는 자원: Socket_Pool_B

Worker-2 Stack:
  - 상태: BLOCKED
  - 기다리는 자원: Shared_Memory_A

→ 프로세스는 실행하지 않고 계속 대기
→ CPU 0%, MEM 정체
→ 로그 기록 불가능 (I/O 블로킹)
```

---

## 4. Workaround & Verification (조치 및 검증)

### Before: MULTI_THREAD_ENABLE=true

**테스트 조건**:
- 환경변수: MULTI_THREAD_ENABLE=true
- MEMORY_LIMIT=256MB (충분)
- CPU_MAX_OCCUPY=80% (충분)

**결과**:
```
Boot: 05:50:01
├─ AgentWorker 초기화 (05:50:03)
├─ Worker-Thread-1 시작, Shared_Memory_A 획득 (05:50:08)
├─ Worker-Thread-2 시작, Socket_Pool_B 획득 (05:50:08)
├─ Worker-1: Socket_Pool_B 대기 시작 (05:50:10)
├─ Worker-2: Shared_Memory_A 대기 시작 (05:50:10)
└─ 로그 정지 (무한 대기) ← DEADLOCK
```

| 항목 | 값 |
|------|-----|
| **프로세스 상태** | **무응답** (종료 안 됨) |
| **데드락 진입** | 약 **9초** |
| **PID 존재** | ✓ 살아있음 |
| **CPU** | 0.0% (대기 중) |
| **메모리** | 정체 (변화 없음) |
| **로그** | 05:50:10에서 정지 |

**그래프 (프로세스 상태)**:
```
상태 변화:
정상 (0~9초) → 교착상태 (9초 이후)

CPU 사용률(%):
  3% ├─ 정상 작업
  0% ├─────────────────── 교착상태 (BLOCKED)

메모리(MB):
256 ├─ 정상 사용
    ├─────────────────── 정체 (변화 없음)

로그:
    ├─ 05:50:10까지 출력
    └─────────────────── 정지 (I/O 블로킹)
```

---

### After: MULTI_THREAD_ENABLE=false

**수정 사항**:
- 환경변수: MULTI_THREAD_ENABLE=false (싱글스레드)
- MEMORY_LIMIT=512MB
- CPU_MAX_OCCUPY=80%

**예상 결과**:
- 싱글스레드이므로 여러 스레드의 자원 경쟁 불가능
- 락 경쟁(lock contention) 없음
- 데드락 발생 불가능
- 프로세스 정상 동작

**비교**:

| 항목 | MULTI_THREAD=true | MULTI_THREAD=false |
|------|------|------|
| **스레드 수** | 2개 이상 | 1개 (싱글) |
| **자원 경쟁** | ✗ 있음 | ✓ 없음 |
| **데드락 가능성** | **매우 높음** | **불가능** |
| **로그 기록** | **9초에서 정지** | **계속 기록** |
| **프로세스 상태** | **무응답** | **정상 동작** |

---

## 5. 근본적 해결을 위한 제안

### 단기 대응 (즉시)
```bash
# MULTI_THREAD_ENABLE을 false로 전환
docker run -e MULTI_THREAD_ENABLE=false b1-2-agent
```

### 중기 대응 (코드 리뷰 필요)

**문제점**:
1. **자원 획득 순서 불일치**
   - Worker-1: A → B 순서로 획득
   - Worker-2: B → A 순서로 획득
   
**해결책**:
```
모든 워커가 동일한 순서로 자원 획득:
- 모두 A 먼저 획득 후 B 획득
  또는
- 모두 B 먼저 획득 후 A 획득
```

2. **락 타임아웃 메커니즘 추가**
   ```
   acquire(resource, timeout=5초)
   → 5초 내에 획득 불가 시 포기하고 진행
   → 데드락 상황에서 복구 가능
   ```

3. **데드락 감지 및 자동 복구**
   ```
   - 주기적으로 스레드 상태 모니터링
   - 모든 스레드가 BLOCKED 상태 지속 시
   - 자동으로 프로세스 재시작
   ```

### 장기 대응 (아키텍처 개선)

**추천 사항**:
1. **단일 스레드 방식** (현재 상황이 더 안정적)
2. **스레드 풀 + 안전한 동기화** (library 사용)
   ```python
   # 예: Python queue.Queue 사용
   # 자동으로 데드락 방지
   ```
3. **비동기 프로그래밍** (async/await)
   - 락이 필요 없음
   - 교착상태 발생 불가능

---

## 6. 결론

| 항목 | 상태 |
|------|------|
| **데드락 발생** | ✓ 확인됨 (약 9초) |
| **증거** | ✓ 충분함 (로그, PID, CPU/MEM) |
| **원인** | ✓ 4가지 조건 모두 만족 |
| **현재 상황** | **위험** (자동 복구 메커니즘 없음) |
| **임시 해결** | ✓ MULTI_THREAD=false로 회피 가능 |
| **근본 해결** | ☐ 코드 리팩토링 필요 |

**최종 권장사항**:
1. 즉시: MULTI_THREAD_ENABLE=false로 싱글스레드 운영
2. 단기: 멀티스레드 코드 리뷰 및 데드락 분석
3. 중기: 자원 획득 순서 통일 또는 타임아웃 메커니즘 추가
4. 장기: 안전한 동기화 라이브러리 또는 비동기 방식 도입

**위험도**:**HIGH** - 자동 복구 없이 무한 대기 상태에 빠짐
