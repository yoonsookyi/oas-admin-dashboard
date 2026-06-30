# OAS Admin Dashboard

Oracle Analytics Server(OAS) / OBIEE 운영 담당자를 위한 경량 관리 대시보드입니다.  
단일 HTML 파일과 선택적 Python 경량 서버로 구성되어 별도의 애플리케이션 서버 없이 동작합니다.

---

## 주요 기능 (탭 구성)

| 탭 | 기능 | 데이터 출처 |
|---|---|---|
| 🟢 시스템 상태 | OAS 서비스 상태, 버전 정보 | OAS REST API |
| 📈 리소스 | CPU · 메모리 · 디스크 · Swap 실시간 모니터링 | metrics_server.py |
| 📋 로그 분석 | ERROR/WARNING 집계, 키워드 검색 | metrics_server.py (로그 파일 직접 읽기) |
| 📁 콘텐츠 인벤토리 | 워크북·대시보드·데이터셋 현황, 최근 변경 목록 | OAS REST API |
| 📊 사용량 분석 | 많이 사용된 리포트, 느린 쿼리, 미사용 콘텐츠 감지 | Usage Tracking DB (S_NQ_ACCT) |
| 🔍 소유자 없는 콘텐츠 | 계정 삭제된 사용자의 고아 콘텐츠 탐지 | OAS REST API |
| 🔼 업그레이드 진단 | OAS/OBIEE → OAS 2026 업그레이드 사전 진단 및 보고서 | OAS REST API + 수동 입력 |
| 🔧 패치·점검 | 스냅샷/백업 생성·관리, 업그레이드 체크리스트 | metrics_server.py |
| 📖 Runbook | 기동·종료·백업·복구 절차 가이드 | 정적 문서 |

---

## 구성 파일

```
oas-admin-dashboard/
├── index.html          # 대시보드 (단일 HTML — 브라우저에서 바로 실행)
├── metrics_server.py   # VM 경량 HTTP 서버 (Python 3.8+)
└── backup.sh           # OAS 스냅샷/백업 스크립트 (bash)
```

---

## 배포 옵션

### Option A — 경량 배포 (HTML 파일만)

OAS REST API 범위 내 기능만 사용합니다. Python 서버 불필요.

**가능한 탭:** 시스템 상태 · 콘텐츠 인벤토리 · 소유자 없는 콘텐츠 · 업그레이드 진단 · Runbook

```bash
# OHS document root 또는 WebLogic 정적 리소스 경로에 복사
cp index.html /u01/oracle/config/OracleBIApplication/coreapplication/OHS/ohs1/htdocs/oas-dashboard.html
```

브라우저에서 `http://서버IP:7777/oas-dashboard.html` 열기 → OAS URL·계정 입력 → 연결

---

### Option B — 전체 기능 배포

리소스 모니터링, 로그 분석, 스냅샷, 사용량 분석 탭을 포함한 전체 기능을 사용합니다.

#### Step 1 — VM에 파일 배치 및 패키지 설치

```bash
mkdir -p /opt/oas-metrics /backup/oas-snapshots
cp metrics_server.py /opt/oas-metrics/
cp backup.sh /opt/oas-metrics/
chmod +x /opt/oas-metrics/backup.sh

pip3 install psutil        # 리소스 모니터링 (필수)
pip3 install oracledb      # Usage Tracking DB 연결 (선택)
```

#### Step 2 — 환경변수 설정 및 서버 기동

```bash
cat > /opt/oas-metrics/start.sh << 'EOF'
#!/bin/bash
export ORACLE_HOME=/u01/oracle/products/OAS
export ORACLE_INSTANCE=/u01/oracle/config/OracleBIApplication/coreapplication
export DOMAIN_HOME=/u01/oracle/config/domains/bi

# Usage Tracking DB 연결 (선택 — OAS Usage Tracking 활성화 필요)
# export OAS_UT_USER=biplatform
# export OAS_UT_PASS=<password>
# export OAS_UT_DSN=localhost:1521/<service_name>

python3 /opt/oas-metrics/metrics_server.py &
echo $! > /var/run/oas-metrics.pid
EOF
chmod +x /opt/oas-metrics/start.sh
/opt/oas-metrics/start.sh
```

#### Step 3 — OHS ProxyPass 설정

`httpd.conf` 또는 OHS 설정 파일에 아래 2줄 추가 후 OHS 재시작:

```apache
ProxyPass        /sysmgmt  http://localhost:9091
ProxyPassReverse /sysmgmt  http://localhost:9091
```

```bash
# OHS 재시작
opmnctl restartproc ias-component=ohs1
```

---

## metrics_server.py 엔드포인트

| 엔드포인트 | 설명 |
|---|---|
| `GET /metrics` | CPU · 메모리 · 디스크 · Swap 현황 |
| `GET /version` | OAS 설치 버전 자동 감지 (OPatch / inventory) |
| `GET /logs?file=obips&level=ERROR&lines=500` | OAS 로그 파일 파싱 결과 |
| `GET /usage?period=90&top=20` | Usage Tracking 통계 (S_NQ_ACCT) |
| `GET /snapshots` | 스냅샷 파일 목록 |
| `POST /snapshot` | 스냅샷 생성 (backup.sh 비동기 실행) |

> 기본 포트: `9091` (localhost only) — OHS ProxyPass를 통해 브라우저에 노출

---

## 지원 로그 파일

| 키 | 파일 | 내용 |
|---|---|---|
| `obips` | `coreapplication_obips1/sawlog0.log` | Presentation Services |
| `nqserver` | `coreapplication_obis1/nqserver.log` | BI Server 실행 로그 |
| `nqquery` | `coreapplication_obis1/nqquery.log` | 쿼리 실행 기록 |
| `obisch` | `coreapplication_obisch1/obisch1.log` | 스케줄러 |
| `domain` | `bi_server1/logs/bi_server1.log` | WebLogic 관리 서버 |
| `admin` | `AdminServer/logs/AdminServer.log` | WebLogic Admin 서버 |
| `ohs` | `OHS/ohs1/error_log` | OHS 에러 로그 |

---

## Usage Tracking 설정 (선택)

`사용량 분석` 탭을 사용하려면 OAS에서 Usage Tracking이 활성화되어 있어야 합니다.

**OAS Usage Tracking 활성화:**  
`NQSConfig.INI` → `[USAGE_TRACKING]` 섹션에서 `ENABLE = YES` 설정 후 BI Server 재시작

**확인:**
```sql
SELECT COUNT(*) FROM biplatform.S_NQ_ACCT;
```

---

## 요구사항

| 구분 | 요구사항 |
|---|---|
| OAS/OBIEE | OAS 5.x · 6.x · 7.x · 2026 / OBIEE 11g · 12c |
| REST API | OAS REST API `20210901` (포트 7777, Basic Auth) |
| Python | 3.8 이상 (metrics_server.py 사용 시) |
| Python 패키지 | `psutil` (필수), `oracledb` 또는 `cx_Oracle` (Usage Tracking 선택) |
| 브라우저 | Chrome · Edge · Firefox 최신 버전 |

---

## 인증

OAS REST API Basic Authentication을 사용합니다.  
대시보드 상단 설정 바에서 OAS URL · 사용자명 · 비밀번호를 입력 후 연결합니다.  
자격증명은 브라우저 메모리에만 유지되며 서버로 전송하지 않습니다.

---

## 라이선스

이 프로젝트는 사내 운영 도구로 개발되었습니다.
