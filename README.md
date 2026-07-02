# OAS Admin Dashboard

Oracle Analytics Server(OAS) / OBIEE 운영 담당자를 위한 경량 관리 대시보드입니다.  
단일 HTML 파일과 선택적 Python 경량 서버로 구성되어 별도의 애플리케이션 서버 없이 동작합니다.

---

## 구성 파일

```
oas-admin-dashboard/
├── oas-dashboard.html  # 대시보드 (단일 HTML)
├── metrics_server.py   # VM 경량 HTTP 서버 (Python 3.6+)
├── backup.sh           # OAS 스냅샷/백업 스크립트
└── deploy.sh           # 배포 자동화 스크립트
```

---

## 요구사항

| 구분 | 요구사항 |
|---|---|
| OAS/OBIEE | OAS 5.x · 6.x · 7.x · 2026 / OBIEE 11g · 12c |
| REST API | OAS REST API `20210901` (Basic Auth) |
| Python | 3.6 이상 (Option B 사용 시, 3.8 이상 권장) |
| Python 패키지 | `psutil` (필수), `oracledb` (Usage Tracking 선택) |
| 브라우저 | Chrome · Edge · Firefox 최신 버전 |
| 배포 계정 | `oracle` (OAS 설치 계정) — 모든 작업 oracle 계정으로 실행 |

---

## 배포 옵션

| 옵션 | 사용 가능한 탭 | 추가 작업 |
|---|---|---|
| **Option A** | 시스템 상태 · 콘텐츠 인벤토리 · Runbook | 없음 |
| **Option B** | Option A 전체 + 리소스 · 로그 분석 · 패치·점검 · 사용량 분석 | Python 서버 기동, OHS ProxyPass 설정 |

> Option B는 Option A를 전제합니다.

---

## 배포 — deploy.sh (권장)

`deploy.sh` 하나로 모든 배포 단계를 자동 처리합니다.  
`oracle` 계정으로 실행하며 root 권한이 필요 없습니다.

```bash
# oracle 계정으로 실행
bash deploy.sh a   # Option A
bash deploy.sh b   # Option B
```

**자동 처리 항목:**

| 단계 | 내용 |
|---|---|
| 환경 감지 | ORACLE_HOME · ORACLE_INSTANCE · DOMAIN_HOME · OHS 경로를 Oracle Inventory·실행 프로세스·특성 파일 순으로 자동 탐색 |
| 경로 확인 | 탐색 결과를 화면에 출력, 틀린 경우 직접 수정 입력 가능 |
| 파일 배치 | OHS `httpd.conf`의 `DocumentRoot` 기준으로 htdocs를 확정하고, `oas-dashboard.html` 복사 후 원본/대상 파일을 검증 |
| Python 설치 | Python 3.6은 `psutil==5.9.8` / `oracledb==1.4.2` 호환 wheel 설치, 설치 후 import 검증 |
| start.sh 생성 | 환경변수 포함한 기동 스크립트 자동 생성 |
| ProxyPass | OHS httpd.conf에 `/sysmgmt` 프록시 설정 추가 (기존 설정 자동 백업) |
| OAS 재시작 | `$DOMAIN_HOME/bitools/bin/stop.sh -noprompt` → `start.sh -noprompt` 실행 및 동작 확인 |

감지 실패 항목은 스크립트가 직접 입력을 요청합니다.

---

## 배포 — 수동 절차 (참고)

deploy.sh 사용을 권장합니다. 수동 배포가 필요한 경우 아래 절차를 따릅니다.

### Option A — HTML 파일 배포

```bash
# 실행 중인 httpd 프로세스에서 DocumentRoot 확인
ps -ef | grep httpd | grep -v grep
grep "DocumentRoot" <httpd.conf경로>

cp oas-dashboard.html <OHS_HTDOCS>/oas-dashboard.html
```

접속 확인: `http://서버IP:<OHS포트>/oas-dashboard.html`

### Option B — 전체 기능 배포

```bash
# 1. 디렉터리 생성 및 파일 배치
mkdir -p <INSTALL_DIR>
mkdir -p <BACKUP_DIR>
cp metrics_server.py backup.sh <INSTALL_DIR>/
chmod +x <INSTALL_DIR>/backup.sh

# 2. Python 패키지 설치 (oracle 계정)
pip3 install --user psutil
pip3 install --user oracledb   # Usage Tracking 사용 시
# Python 3.6 환경에서는 deploy.sh가 psutil==5.9.8, oracledb==1.4.2를 자동 사용

# 3. start.sh 작성 후 기동
cat > <INSTALL_DIR>/start.sh << 'EOF'
#!/bin/bash
export ORACLE_HOME=<실제경로>
export DOMAIN_HOME=<실제경로>
# export OAS_UT_USER=<DB계정>
# export OAS_UT_PASS=<password>
# export OAS_UT_DSN=<host>:<port>/<service>
# export OAS_UT_TABLE=<스키마.테이블명>
python3 <INSTALL_DIR>/metrics_server.py &
echo $! > <INSTALL_DIR>/oas-metrics.pid
EOF
chmod +x <INSTALL_DIR>/start.sh
<INSTALL_DIR>/start.sh

# 4. OHS ProxyPass 설정 추가 (httpd.conf 경로는 httpd 프로세스에서 확인)
echo "ProxyPass        /sysmgmt  http://localhost:9091" >> <httpd.conf경로>
echo "ProxyPassReverse /sysmgmt  http://localhost:9091" >> <httpd.conf경로>

# 5. OAS 재시작
<DOMAIN_HOME>/bitools/bin/stop.sh -noprompt
<DOMAIN_HOME>/bitools/bin/start.sh -noprompt

# 6. 동작 확인
curl -s http://127.0.0.1:9091/metrics
curl -s http://localhost:<OHS포트>/sysmgmt/metrics
```

---

## Usage Tracking 설정 (선택)

`사용량 분석` 탭은 OAS Usage Tracking이 활성화되어 있어야 합니다.

> ⚠ **NQSConfig.INI 직접 편집 금지**  
> NQSConfig.INI는 OAS Console이 관리하는 파생 파일로, Console에서 설정 저장 시 덮어써집니다.  
> 참고: [Set Usage Tracking Parameters](https://docs.oracle.com/en/middleware/bi/analytics-server/administer-oas/set-usage-tracking-parameters.html)

### Step 1 — OAS Console에서 활성화

```
http://서버포트/ui
→ Navigator(≡) → Console → Advanced System Settings → Usage Tracking
→ Enable Usage Tracking 체크
```

| 파라미터 | 형식 | 예시 |
|---|---|---|
| Connection Pool | `<DB명>.<Pool명>` | `UsageTracking.UTConnectionPool` |
| Init Block Table | `<DB명>.<스키마>.<테이블>` | `UsageTracking.UT_Schema.InitBlockInfo` |
| Physical Query Table | `<DB명>.<스키마>.<테이블>` | `UsageTracking.UT_Schema.PhysicalQueries` |
| Logical Query Table | `<DB명>.<스키마>.<테이블>` | `UsageTracking.UT_Schema.LogicalQueries` |
| Max Rows | 1 ~ 100,000 (0=무제한) | `10000` |

Apply → OAS 재시작:
```bash
<DOMAIN_HOME>/bitools/bin/stop.sh -noprompt
<DOMAIN_HOME>/bitools/bin/start.sh -noprompt

# 상태 확인
<DOMAIN_HOME>/bitools/bin/status.sh -v
```

### Step 2 — NQSConfig.INI 반영 확인

```bash
grep -A 15 '\[USAGE_TRACKING\]' \
  /u01/data/domains/bi/config/fmwconfig/biconfig/OBIS/NQSConfig.INI
# ENABLE = YES, DIRECT_INSERT = YES 확인
```

### Step 3 — start.sh 환경변수 설정 후 재기동

```bash
vi <INSTALL_DIR>/start.sh
# OAS_UT_USER / OAS_UT_PASS / OAS_UT_DSN / OAS_UT_TABLE 주석 해제 후 값 입력

kill $(cat <INSTALL_DIR>/oas-metrics.pid)
<INSTALL_DIR>/start.sh

# 확인
curl -s "http://127.0.0.1:9091/usage?period=7" | python3 -m json.tool
# "configured": true 이면 정상
```

---

## OAS 서비스 관리

OAS 프로세스는 `$DOMAIN_HOME/bitools/bin/` 스크립트로 관리합니다.  
참고: [Use Commands to Start, Stop, and View Status of Processes](https://docs.oracle.com/en/middleware/bi/analytics-server/administer-oas/use-commands-start-stop-and-view-status-processes.html)

```bash
# 전체 기동 (-noprompt: 대화형 프롬프트 없이 실행)
$DOMAIN_HOME/bitools/bin/start.sh -noprompt

# 전체 중지
$DOMAIN_HOME/bitools/bin/stop.sh -noprompt

# 상태 확인 (-v: 상세 정보)
$DOMAIN_HOME/bitools/bin/status.sh -v

# 특정 인스턴스만 재시작
$DOMAIN_HOME/bitools/bin/stop.sh  -noprompt -i obis1,obips1
$DOMAIN_HOME/bitools/bin/start.sh -noprompt -i obis1,obips1
```

| 옵션 | 설명 |
|---|---|
| `-noprompt` | 대화형 프롬프트 없이 실행 (스크립트 자동화 시 필수) |
| `-i <인스턴스>` | 쉼표 구분 인스턴스 지정 (예: `obis1,obips1`) |
| `-v` | 상태 상세 출력 (status.sh 전용) |
| `-c` | 캐시된 자격증명 초기화 |

---

## 기존 OAS 환경의 변화

### Option A 배포 후

```
OHS (port 7777)
├── /analytics            → OAS Presentation Services  (기존)
├── /xmlpserver           → BI Publisher               (기존)
└── /oas-dashboard.html   → oas-dashboard.html 정적 파일  (신규)
```
OAS 프로세스·포트·설정 변경 없음

### Option B 배포 후 추가

```
신규 프로세스
└── metrics_server.py  → 127.0.0.1:9091  (oracle 계정, 서버 내부 전용)

신규 디렉터리
├── <INSTALL_DIR>/      metrics_server.py · backup.sh · start.sh
└── <BACKUP_DIR>/       스냅샷·백업 파일

OHS httpd.conf 변경
└── ProxyPass /sysmgmt → http://127.0.0.1:9091  (신규)

OHS (port 7777) 라우팅 추가
└── /sysmgmt/*  → metrics_server.py (9091) 프록시  (신규)
```
포트 9091은 외부 노출 없음 · OHS 재시작 1회 필요

### 브라우저 요청 흐름

```
브라우저
 │
 ├─ GET /oas-dashboard.html ──────────────→ OHS → oas-dashboard.html 반환
 │
 ├─ OAS REST API 호출 ────────────────────→ OHS → Presentation Services → JSON
 │   (시스템 상태·콘텐츠·소유자·업그레이드)
 │
 └─ GET /sysmgmt/* ───────────────────────→ OHS (ProxyPass)
                                               → metrics_server.py :9091
                                               → JSON 반환
     (리소스·로그·스냅샷·사용량)
```

---

## 대시보드 사용 방법

### 초기 연결

브라우저에서 `http://서버IP:<OHS포트>/oas-dashboard.html` 접속 후  
상단 설정 바에 아래 값을 입력하고 **연결** 버튼을 클릭합니다.

| 항목 | 설명 | 예시 |
|---|---|---|
| OAS URL | OAS 서버 주소 (포트 포함) | `http://192.168.1.10:7777` |
| 사용자명 | OAS 관리자 계정 | `weblogic` |
| 비밀번호 | 해당 계정 비밀번호 | |

> 자격증명은 브라우저 메모리에만 유지되며 서버로 전송되지 않습니다.

---

### 🟢 시스템 상태

OAS 핵심 서비스의 현재 상태와 버전 정보를 확인합니다.

| 항목 | 내용 |
|---|---|
| 서비스 상태 | Presentation Services · BI Server · Scheduler · Cluster Controller 기동 여부 |
| 버전 정보 | OAS/OBIEE 설치 버전 (OPatch 또는 inventory 파일 기반) |

**활용:** 서비스 이상 발생 시 가장 먼저 확인. 버전 확인은 패치 적용 전후 검증에 사용.

---

### 📈 리소스 모니터링 _(Option B 필요)_

서버의 시스템 자원 현황을 실시간으로 확인합니다.

| 항목 | 내용 |
|---|---|
| CPU | 전체 사용률 (%) · 코어 수 |
| 메모리 | 전체 / 사용 / 여유 (GB) · 사용률 (%) |
| Swap | 전체 / 사용 / 여유 · 사용률 (%) |
| 디스크 | 마운트 포인트별 전체 / 사용 / 여유 · 사용률 (%) |

**활용:** 배치 처리·대용량 쿼리 실행 중 자원 병목 확인. Swap 사용률이 높으면 메모리 증설 또는 쿼리 최적화 검토.

**새로고침:** 페이지 상단 새로고침 버튼 또는 브라우저 새로고침

---

### 📋 로그 분석 _(Option B 필요)_

OAS 로그 파일을 서버에서 직접 읽어 ERROR·WARNING을 분석합니다.

**사용 순서:**
1. 로그 파일 선택 (기본: `bi_server1` - OAS Managed Server)
2. 레벨 필터 선택 (ERROR / WARNING / 전체)
3. 조회할 줄 수 입력 (기본 500줄)
4. **조회** 버튼 클릭

| 로그 키 | 파일 | 확인 대상 |
|---|---|---|
| `bi_server1` | `bi_server1.log` | OAS Managed Server 오류 |
| `adminserver` | `AdminServer.log` | WebLogic AdminServer 오류 |
| `obis1` | `obis1.log` | BI Server 오류 |

**키워드 검색:** 조회 결과에서 특정 오류 메시지나 사용자명으로 필터링 가능

---

### 📁 콘텐츠 인벤토리

OAS 카탈로그의 전체 콘텐츠 현황과 최근 변경 이력을 조회합니다.

| 항목 | 내용 |
|---|---|
| 전체 현황 | 워크북 · 대시보드 · 데이터셋 · 폴더 수량 |
| 최근 변경 | 최근 수정된 콘텐츠 목록 (수정자, 수정일시) |

**활용:** 콘텐츠 증가 추이 파악. 무단 수정 또는 예기치 않은 변경 탐지.

---

### 📊 사용량 분석 _(Option B + Usage Tracking 필요)_

Usage Tracking DB를 기반으로 리포트 활용 현황을 분석합니다.

**사용 순서:**
1. 분석 기간 선택 (30 / 90 / 180 / 365일)
2. **조회** 버튼 클릭

| 항목 | 내용 | 활용 |
|---|---|---|
| 요약 통계 | 총 쿼리 수 · 오류율 · 활성 사용자 · 평균 응답시간 | 전체 사용 추이 파악 |
| 일별 추이 | 최근 30일 쿼리량·오류 막대 차트 | 특정 일 급증·급감 원인 분석 |
| 많이 사용된 리포트 | 조회수 상위 20개, 평균 응답시간·마지막 사용일 | 핵심 리포트 파악 |
| 느린 리포트 | 평균 응답시간 상위 (3회 이상 실행된 것) | 성능 최적화 대상 선별 |
| 상위 사용자 | 사용자별 조회수·리포트 수 | 헤비 유저 파악 |
| Subject Area | 주제 영역별 사용 빈도 | 데이터 모델 관리 우선순위 결정 |
| 미사용 콘텐츠 | 선택 기간 내 Usage Tracking에 없는 카탈로그 항목 | 정리 대상 콘텐츠 탐지 |

> Usage Tracking 미활성화 시 활성화 방법이 화면에 안내됩니다.

---

### 🔧 패치·점검 _(Option B 필요)_

OAS 스냅샷 생성·관리 및 업그레이드 체크리스트를 제공합니다.

**스냅샷 생성:**
1. **스냅샷 생성** 버튼 클릭
2. `backup.sh`가 서버에서 비동기 실행
3. 완료 후 스냅샷 목록에 파일 표시

**스냅샷 내용:**

| 대상 | 파일명 형식 |
|---|---|
| WebLogic 도메인 설정 | `domain_config_YYYYMMDD_HHMMSS.tar.gz` |
| OAS 카탈로그 | `catalog_YYYYMMDD_HHMMSS.tar.gz` |
| RPD (리포지터리) | `rpd_YYYYMMDD_HHMMSS/` |

> 30일 이상 된 스냅샷은 자동 삭제됩니다.

**업그레이드 체크리스트:** 패치 적용 또는 업그레이드 전 수행 항목을 단계별로 확인

---

### 📖 Runbook

OAS 기동·종료·백업·복구 표준 절차를 정리한 정적 가이드입니다.

| 항목 | 내용 |
|---|---|
| 기동 절차 | 컴포넌트 순서별 기동 방법 |
| 종료 절차 | 정상 종료 순서 |
| 백업 절차 | 수동 백업 방법 |
| 복구 절차 | 장애 상황별 복구 방법 |

---

## metrics_server.py 엔드포인트

| 엔드포인트 | 설명 |
|---|---|
| `GET /metrics` | CPU · 메모리 · 디스크 · Swap 현황 |
| `GET /version` | OAS 버전 자동 감지 (OPatch / inventory) |
| `GET /logs?file=bi_server1&level=ERROR&lines=500` | OAS 로그 파일 파싱 결과 |
| `GET /usage?period=90&top=20` | Usage Tracking 통계 (LogicalQueries) |
| `GET /snapshots` | 스냅샷 파일 목록 |
| `POST /snapshot` | 스냅샷 생성 (backup.sh 비동기 실행) |

> 기본 포트: `9091` (127.0.0.1 전용) — OHS ProxyPass를 통해 브라우저에 노출

---

## 라이선스

이 프로젝트는 사내 운영 도구로 개발되었습니다.
