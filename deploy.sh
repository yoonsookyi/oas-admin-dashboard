#!/bin/bash
# OAS Admin Dashboard 배포 스크립트
# 사용법: bash deploy.sh [a|b]
#   a — Option A (HTML만)
#   b — Option B (전체 기능)
#   인수 없이 실행하면 대화형으로 선택

set -euo pipefail

# ── 색상 ────────────────────────────────────────────────────
C_GRN='\033[0;32m'; C_YLW='\033[1;33m'
C_RED='\033[0;31m'; C_BLD='\033[1m'; C_CYN='\033[0;36m'; C_NC='\033[0m'

ok()   { echo -e "  ${C_GRN}[OK]${C_NC}  $*"; }
info() { echo -e "  ${C_YLW}[--]${C_NC}  $*"; }
err()  { echo -e "  ${C_RED}[!!]${C_NC}  $*"; }
src()  { echo -e "       ${C_CYN}→ $*${C_NC}"; }
hdr()  { echo -e "\n${C_BLD}━━  $*  ━━${C_NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# oracle 계정 실행 확인
if [[ "$(id -u)" -eq 0 ]]; then
  echo -e "  ${C_YLW}[경고]${C_NC} root로 실행 중입니다. oracle 계정으로 실행하세요."
  read -rp "  계속 진행하시겠습니까? [y/N]: " _root_ok
  [[ "${_root_ok,,}" != "y" ]] && exit 1
fi

# ── 탐색 기준 경로 (oracle이 읽을 수 있는 마운트 포인트만) ──
# find / 대신 Oracle 설치 관례 경로만 탐색하여 속도·권한 문제 회피
SEARCH_ROOTS=""
for _r in /u01 /u02 /u03 /u04 /oracle /opt/oracle /home/oracle \
          /data /app/oracle "$HOME"; do
  [[ -d "$_r" ]] && SEARCH_ROOTS="$SEARCH_ROOTS $_r"
done
SEARCH_ROOTS="${SEARCH_ROOTS# }"   # 앞 공백 제거

# ════════════════════════════════════════════════════════════
# 경로 자동 탐지 함수들
# 탐지 우선순위: ① 환경변수 → ② Oracle Inventory →
#               ③ 실행 프로세스 → ④ 특성 파일 검색 → ⑤ 일반 경로
# ════════════════════════════════════════════════════════════

# Oracle Inventory에서 OAS/OBIEE 홈 목록 추출
_inventory_homes() {
  local inv_loc="/etc/oraInst.loc"
  [[ ! -f "$inv_loc" ]] && return
  local inv_dir
  inv_dir=$(awk -F= '/inventory_loc/{gsub(/ /,"",$2); print $2}' "$inv_loc" 2>/dev/null)
  local inv_xml="$inv_dir/ContentsXML/inventory.xml"
  [[ ! -f "$inv_xml" ]] && return
  # OAS / Oracle BI 관련 홈만 추출
  grep -oE 'LOC="[^"]+"' "$inv_xml" 2>/dev/null \
    | sed 's/LOC="//;s/"//' \
    | while read -r home; do
        [[ -d "$home/OPatch" || -d "$home/bifoundation" ]] && echo "$home"
      done
}

# 실행 중인 OAS 프로세스에서 경로 힌트 추출
_proc_hint() {
  local pattern="$1"
  ps -eo args 2>/dev/null | grep -v grep | grep -oE "$pattern" | head -1
}

# ORACLE_HOME 탐지
detect_oracle_home() {
  local val="${ORACLE_HOME:-}"

  # ① 환경변수
  if [[ -n "$val" && -d "$val/OPatch" ]]; then
    echo "$val"; return
  fi

  # ② Oracle Inventory
  local inv_home
  inv_home=$(_inventory_homes | head -1)
  [[ -n "$inv_home" ]] && echo "$inv_home" && return

  # ③ 실행 프로세스 (nqserver, sawserver 등)
  local proc_home
  proc_home=$(ps -eo args 2>/dev/null | grep -v grep \
    | grep -E "nqserver|sawserver|obisch" \
    | grep -oE '[^ ]+/OPatch' | sed 's|/OPatch||' | head -1)
  [[ -n "$proc_home" && -d "$proc_home" ]] && echo "$proc_home" && return

  # ④ opmnctl 위치로 역추산
  local opmn_path
  opmn_path=$(command -v opmnctl 2>/dev/null || true)
  if [[ -n "$opmn_path" ]]; then
    # opmnctl 은 보통 $ORACLE_HOME/opmn/bin/opmnctl
    local h
    h=$(dirname "$(dirname "$(dirname "$opmn_path")")")
    [[ -d "$h/OPatch" ]] && echo "$h" && return
  fi

  # ⑤ 일반 경로 패턴
  for p in \
    /u01/oracle/products/OAS   /u01/oracle/products/obiee \
    /u01/app/oracle/product/OAS /opt/oracle/OAS \
    /u02/oracle/products/OAS   /oracle/products/OAS; do
    [[ -d "$p/OPatch" ]] && echo "$p" && return
  done

  echo ""
}

# ORACLE_INSTANCE 탐지
detect_oracle_instance() {
  local val="${ORACLE_INSTANCE:-}"

  # ① 환경변수
  [[ -n "$val" && -d "$val/diagnostics" ]] && echo "$val" && return

  # ② NQSConfig.INI 위치로 역추산
  #    경로 구조: $ORACLE_INSTANCE/config/OracleBIServerComponent/.../NQSConfig.INI
  local nqs
  nqs=$(find $SEARCH_ROOTS -maxdepth 10 -name "NQSConfig.INI" \
        -not -path "*/backup/*" -not -path "*/tmp/*" 2>/dev/null | head -1)
  if [[ -n "$nqs" ]]; then
    # NQSConfig.INI → .../config/OracleBIServerComponent/xxx/NQSConfig.INI
    # ORACLE_INSTANCE = config의 두 단계 위
    local inst
    inst=$(dirname "$(dirname "$(dirname "$nqs")")")
    [[ -d "$inst/diagnostics" ]] && echo "$inst" && return
  fi

  # ③ opmn.xml 위치로 탐지
  local opmn_xml
  opmn_xml=$(find / -maxdepth 10 -name "opmn.xml" \
             -not -path "*/backup/*" 2>/dev/null | head -1)
  if [[ -n "$opmn_xml" ]]; then
    local inst
    inst=$(dirname "$(dirname "$opmn_xml")")
    [[ -d "$inst/diagnostics" ]] && echo "$inst" && return
  fi

  # ④ 실행 프로세스에서 ORACLE_INSTANCE 추출
  local proc_inst
  proc_inst=$(ps -eo args 2>/dev/null | grep -v grep \
    | grep -oE 'ORACLE_INSTANCE=[^ ]+' | head -1 | cut -d= -f2)
  [[ -n "$proc_inst" && -d "$proc_inst" ]] && echo "$proc_inst" && return

  # ⑤ ORACLE_HOME 기준 상대 경로 탐색
  local oh="${ORACLE_HOME:-}"
  if [[ -n "$oh" ]]; then
    local base
    base=$(dirname "$(dirname "$oh")")   # 보통 $base/products/OAS 구조
    for p in \
      "$base/config/OracleBIApplication/coreapplication" \
      "$base/instance/OracleBIApplication/coreapplication"; do
      [[ -d "$p/diagnostics" ]] && echo "$p" && return
    done
  fi

  echo ""
}

# DOMAIN_HOME 탐지
detect_domain_home() {
  local val="${DOMAIN_HOME:-}"

  # ① 환경변수
  [[ -n "$val" && -f "$val/config/config.xml" ]] && echo "$val" && return

  # ② WebLogic config.xml 탐색 (bifoundation_domain 또는 bi 도메인)
  local cfg
  cfg=$(find $SEARCH_ROOTS -maxdepth 10 -name "config.xml" \
        -path "*/domains/*/config/config.xml" \
        -not -path "*/backup/*" 2>/dev/null \
    | while read -r f; do
        grep -q "bi\|OracleBI\|analytics" "$f" 2>/dev/null && echo "$f"
      done | head -1)
  if [[ -n "$cfg" ]]; then
    echo "$(dirname "$(dirname "$cfg")")"
    return
  fi

  # ③ 실행 중인 WebLogic 프로세스에서 추출
  local wl_home
  wl_home=$(ps -eo args 2>/dev/null | grep -v grep \
    | grep "weblogic.Server" \
    | grep -oE 'Dweblogic.Domain=[^ ]+' | head -1 | cut -d= -f2)
  [[ -n "$wl_home" && -d "$wl_home" ]] && echo "$wl_home" && return

  # ④ AdminServer 로그 디렉터리 탐색
  local adm_log
  adm_log=$(find $SEARCH_ROOTS -maxdepth 10 -name "AdminServer.log" \
            -not -path "*/backup/*" 2>/dev/null | head -1)
  if [[ -n "$adm_log" ]]; then
    # .../domains/<domain>/servers/AdminServer/logs/AdminServer.log
    echo "$(dirname "$(dirname "$(dirname "$(dirname "$adm_log")")")")"
    return
  fi

  # ⑤ ORACLE_INSTANCE 기준 상대 탐색
  local oi="${ORACLE_INSTANCE:-}"
  if [[ -n "$oi" ]]; then
    local base
    base=$(dirname "$(dirname "$oi")")
    for p in \
      "$base/domains/bi" \
      "$base/domains/bifoundation_domain" \
      "/u01/data/domains/bi"; do
      [[ -f "$p/config/config.xml" ]] && echo "$p" && return
    done
  fi

  echo ""
}

# OHS htdocs 탐지
detect_ohs_htdocs() {
  local oi="${ORACLE_INSTANCE:-}"

  # ① ORACLE_INSTANCE 하위 직접 탐색
  if [[ -n "$oi" ]]; then
    for p in \
      "$oi/OHS/ohs1/htdocs" \
      "$oi/config/OHS/ohs1/htdocs" \
      "$oi/OHS/ohs2/htdocs"; do
      [[ -d "$p" ]] && echo "$p" && return
    done
  fi

  # ② httpd.conf의 DocumentRoot 추출
  local conf
  conf=$(detect_ohs_conf)
  if [[ -n "$conf" && -f "$conf" ]]; then
    local docroot
    docroot=$(grep -E "^DocumentRoot" "$conf" 2>/dev/null \
      | head -1 | awk '{print $2}' | tr -d '"')
    [[ -n "$docroot" && -d "$docroot" ]] && echo "$docroot" && return
  fi

  # ③ 시스템 전체 htdocs 탐색 (OHS 특성 파일 함께 있는 곳)
  find $SEARCH_ROOTS -maxdepth 10 -type d -name "htdocs" \
       -not -path "*/backup/*" -not -path "*/tmp/*" 2>/dev/null \
    | while read -r d; do
        # 같은 레벨에 OHS 관련 파일이 있는지 확인
        [[ -f "$(dirname "$d")/conf/httpd.conf" ]] && echo "$d" && break
      done | head -1

  echo ""
}

# OHS httpd.conf 탐지
detect_ohs_conf() {
  local oi="${ORACLE_INSTANCE:-}"

  # ① ORACLE_INSTANCE 하위 직접 탐색
  if [[ -n "$oi" ]]; then
    for p in \
      "$oi/OHS/ohs1/conf/httpd.conf" \
      "$oi/config/OHS/ohs1/conf/httpd.conf" \
      "$oi/OHS/ohs2/conf/httpd.conf"; do
      [[ -f "$p" ]] && echo "$p" && return
    done
  fi

  # ② 시스템 전체 탐색 (OHS 특성: mod_ohs 로드 구문 포함)
  find $SEARCH_ROOTS -maxdepth 10 -name "httpd.conf" \
       -not -path "*/backup/*" -not -path "*/tmp/*" 2>/dev/null \
    | while read -r f; do
        grep -qE "mod_ohs|ohs_module|OracleHTTPServer" "$f" 2>/dev/null \
          && echo "$f" && break
      done | head -1

  echo ""
}

# OHS 포트 탐지 (httpd.conf Listen 지시어)
detect_ohs_port() {
  local conf="${OHS_CONF:-}"
  [[ -z "$conf" ]] && conf=$(detect_ohs_conf)
  if [[ -n "$conf" && -f "$conf" ]]; then
    local port
    port=$(grep -E "^Listen " "$conf" 2>/dev/null \
      | grep -oE '[0-9]+' | tail -1)
    [[ -n "$port" ]] && echo "$port" && return
  fi
  echo "7777"   # OAS 기본값
}

# OHS 컴포넌트명 탐지 (opmnctl 재시작에 사용)
detect_ohs_component() {
  local oi="${ORACLE_INSTANCE:-}"
  if [[ -n "$oi" ]]; then
    # OHS 디렉터리명으로 추정
    local comp
    comp=$(ls -d "$oi/OHS/"ohs* 2>/dev/null | head -1 | xargs -I{} basename {})
    [[ -n "$comp" ]] && echo "$comp" && return
  fi
  # opmn.xml에서 추출
  local opmn_xml
  opmn_xml=$(find / -maxdepth 10 -name "opmn.xml" 2>/dev/null | head -1)
  if [[ -n "$opmn_xml" ]]; then
    grep -oE 'id="ohs[^"]*"' "$opmn_xml" 2>/dev/null \
      | head -1 | sed 's/id="//;s/"//'
    return
  fi
  echo "ohs1"   # 기본값
}

# ORACLE_BASE 추정 (설치 디렉터리 기본 경로 산출용)
detect_oracle_base() {
  [[ -n "${ORACLE_BASE:-}" && -d "$ORACLE_BASE" ]] && echo "$ORACLE_BASE" && return
  local oh="${ORACLE_HOME:-}"
  if [[ -n "$oh" ]]; then
    # 일반적인 구조: /u01/oracle/products/OAS → base = /u01/oracle
    local p1 p2
    p1=$(dirname "$oh")   # .../products
    p2=$(dirname "$p1")   # .../oracle (ORACLE_BASE)
    [[ -d "$p2" ]] && echo "$p2" && return
  fi
  # 현재 사용자 홈 기준 (oracle 계정)
  echo "$HOME"
}

# ════════════════════════════════════════════════════════════
# 탐지 결과를 사용자에게 보여주고 필요시 수정 입력받기
# ════════════════════════════════════════════════════════════
confirm_or_input() {
  local label="$1" varname="$2" detected="$3" required="${4:-true}"
  local val="$detected"

  if [[ -n "$val" ]]; then
    echo -e "  ${C_GRN}✔${C_NC} $label"
    echo -e "       $val"
    read -rp "     변경하시겠습니까? [Enter=유지 / 새 경로 입력]: " override
    [[ -n "$override" ]] && val="$override"
  else
    if [[ "$required" == "true" ]]; then
      echo -e "  ${C_RED}✘${C_NC} $label (자동 감지 실패)"
      read -rp "     직접 입력하세요: " val
      while [[ -z "$val" ]]; do
        read -rp "     필수 값입니다. 입력하세요: " val
      done
    else
      echo -e "  ${C_YLW}?${C_NC} $label (자동 감지 실패, 선택 항목)"
      read -rp "     입력하세요 (Enter=건너뜀): " val
    fi
  fi
  eval "$varname=\"\$val\""
}

# ════════════════════════════════════════════════════════════
# 메인
# ════════════════════════════════════════════════════════════
hdr "OAS Admin Dashboard 배포 스크립트"

DEPLOY_OPT="${1:-}"
if [[ -z "$DEPLOY_OPT" ]]; then
  echo "  배포 옵션을 선택하세요:"
  echo "    a) Option A — HTML 파일만 (OAS REST API 기능)"
  echo "    b) Option B — 전체 기능 (리소스·로그·스냅샷·사용량 분석)"
  read -rp "  선택 [a/b]: " DEPLOY_OPT
fi
DEPLOY_OPT="${DEPLOY_OPT,,}"
if [[ "$DEPLOY_OPT" != "a" && "$DEPLOY_OPT" != "b" ]]; then
  err "a 또는 b 를 입력하세요."; exit 1
fi

# ── Step 1: 환경 탐지 ────────────────────────────────────
hdr "Step 1 — 환경 자동 탐지"
echo "  탐지 중... (잠시 대기)"
echo ""

ORACLE_HOME=$(detect_oracle_home)
ORACLE_INSTANCE=$(detect_oracle_instance)
DOMAIN_HOME=$(detect_domain_home)
OHS_HTDOCS=$(detect_ohs_htdocs)
OHS_CONF=$(detect_ohs_conf)
OHS_PORT=$(detect_ohs_port)
OHS_COMPONENT=$(detect_ohs_component)

# 탐지 소스 표시
[[ -n "$ORACLE_HOME"     ]] && src "ORACLE_HOME     ← $ORACLE_HOME"     || src "ORACLE_HOME     ← 미감지"
[[ -n "$ORACLE_INSTANCE" ]] && src "ORACLE_INSTANCE ← $ORACLE_INSTANCE" || src "ORACLE_INSTANCE ← 미감지"
[[ -n "$DOMAIN_HOME"     ]] && src "DOMAIN_HOME     ← $DOMAIN_HOME"     || src "DOMAIN_HOME     ← 미감지"
[[ -n "$OHS_HTDOCS"      ]] && src "OHS htdocs      ← $OHS_HTDOCS"      || src "OHS htdocs      ← 미감지"
[[ -n "$OHS_CONF"        ]] && src "OHS httpd.conf  ← $OHS_CONF"        || src "OHS httpd.conf  ← 미감지"
src "OHS 포트         ← $OHS_PORT"
src "OHS 컴포넌트     ← $OHS_COMPONENT"

# ── Step 2: 사용자 확인 및 보완 ──────────────────────────
hdr "Step 2 — 탐지 결과 확인"
echo "  감지된 경로를 확인하세요. Enter=유지, 새 값 입력=변경"
echo ""

confirm_or_input "ORACLE_HOME    " ORACLE_HOME     "$ORACLE_HOME"
confirm_or_input "ORACLE_INSTANCE" ORACLE_INSTANCE "$ORACLE_INSTANCE"
confirm_or_input "DOMAIN_HOME    " DOMAIN_HOME     "$DOMAIN_HOME"
confirm_or_input "OHS htdocs     " OHS_HTDOCS      "$OHS_HTDOCS"
if [[ "$DEPLOY_OPT" == "b" ]]; then
  confirm_or_input "OHS httpd.conf " OHS_CONF        "$OHS_CONF"
  confirm_or_input "OHS 포트       " OHS_PORT        "$OHS_PORT"
  confirm_or_input "OHS 컴포넌트명 " OHS_COMPONENT   "$OHS_COMPONENT"
fi

# 설치 디렉터리: ORACLE_BASE 기반으로 제안
ORACLE_BASE=$(detect_oracle_base)
DEFAULT_METRICS_DIR="$ORACLE_BASE/scripts/oas-metrics"
DEFAULT_BACKUP_DIR="$ORACLE_BASE/backup/oas-snapshots"

if [[ "$DEPLOY_OPT" == "b" ]]; then
  echo ""
  confirm_or_input "스크립트 설치 경로" METRICS_INSTALL "$DEFAULT_METRICS_DIR"
  confirm_or_input "스냅샷 저장 경로  " BACKUP_INSTALL  "$DEFAULT_BACKUP_DIR"
fi

# 최종 확인
echo ""
echo "  ┌─ 최종 배포 설정 ──────────────────────────────────┐"
printf "  │  %-20s %s\n" "ORACLE_HOME"     "$ORACLE_HOME"
printf "  │  %-20s %s\n" "ORACLE_INSTANCE" "$ORACLE_INSTANCE"
printf "  │  %-20s %s\n" "DOMAIN_HOME"     "$DOMAIN_HOME"
printf "  │  %-20s %s\n" "OHS htdocs"      "$OHS_HTDOCS"
if [[ "$DEPLOY_OPT" == "b" ]]; then
  printf "  │  %-20s %s\n" "OHS httpd.conf"  "$OHS_CONF"
  printf "  │  %-20s %s\n" "OHS 포트"        "$OHS_PORT"
  printf "  │  %-20s %s\n" "OHS 컴포넌트"    "$OHS_COMPONENT"
  printf "  │  %-20s %s\n" "스크립트 설치"   "$METRICS_INSTALL"
  printf "  │  %-20s %s\n" "스냅샷 저장"     "$BACKUP_INSTALL"
fi
echo "  └───────────────────────────────────────────────────┘"
echo ""
read -rp "  위 설정으로 배포를 진행하시겠습니까? [y/N]: " confirm
[[ "${confirm,,}" != "y" ]] && { info "배포를 취소했습니다."; exit 0; }

# ════════════════════════════════════════════════════════════
# Option A — HTML 배포
# ════════════════════════════════════════════════════════════
hdr "Step 3 — HTML 파일 배포"

[[ ! -d "$OHS_HTDOCS" ]] && { err "OHS htdocs 경로가 없습니다: $OHS_HTDOCS"; exit 1; }
cp "$SCRIPT_DIR/index.html" "$OHS_HTDOCS/oas-dashboard.html"
ok "index.html → $OHS_HTDOCS/oas-dashboard.html"

if [[ "$DEPLOY_OPT" == "a" ]]; then
  hdr "Option A 배포 완료"
  ok "브라우저에서 접속하세요:"
  echo "     http://서버IP:${OHS_PORT}/oas-dashboard.html"
  exit 0
fi

# ════════════════════════════════════════════════════════════
# Option B — 전체 기능 배포
# ════════════════════════════════════════════════════════════

# ── Step 4: 디렉터리 및 파일 배치 ────────────────────────
hdr "Step 4 — 디렉터리 생성 및 파일 배치"

mkdir -p "$METRICS_INSTALL"
ok "생성: $METRICS_INSTALL"
mkdir -p "$BACKUP_INSTALL"
ok "생성: $BACKUP_INSTALL"

cp "$SCRIPT_DIR/metrics_server.py" "$METRICS_INSTALL/"
ok "metrics_server.py 복사"
cp "$SCRIPT_DIR/backup.sh" "$METRICS_INSTALL/"
chmod +x "$METRICS_INSTALL/backup.sh"
ok "backup.sh 복사 및 실행권한 부여"

# backup.sh 의 BACKUP_DIR 경로를 실제 환경에 맞게 sed로 치환
sed -i "s|BACKUP_DIR=\"/u01/oas-backup/snapshots\"|BACKUP_DIR=\"$BACKUP_INSTALL\"|g" \
  "$METRICS_INSTALL/backup.sh" 2>/dev/null || true

# metrics_server.py 의 BACKUP_DIR, BACKUP_SCRIPT 경로 치환
sed -i \
  -e "s|BACKUP_DIR\s*=\s*'/u01/oas-backup/snapshots'|BACKUP_DIR    = '$BACKUP_INSTALL'|" \
  -e "s|BACKUP_SCRIPT\s*=\s*'/u01/oas-scripts/oas-metrics/backup.sh'|BACKUP_SCRIPT = '$METRICS_INSTALL/backup.sh'|" \
  "$METRICS_INSTALL/metrics_server.py" 2>/dev/null || true
ok "metrics_server.py 내부 경로 치환 완료"

# ── Step 5: Python 패키지 설치 ────────────────────────────
hdr "Step 5 — Python 패키지 설치"

PY3=$(command -v python3 || command -v python || true)
if [[ -z "$PY3" ]]; then
  err "python3 를 찾을 수 없습니다. Python 3.8 이상을 설치하세요."; exit 1
fi
ok "Python: $($PY3 --version 2>&1)"

PIP3=$(command -v pip3 || command -v pip || true)
if [[ -n "$PIP3" ]]; then
  # --user 플래그: oracle 계정이 시스템 Python을 사용할 때 root 권한 불필요
  $PIP3 install --quiet --user psutil && ok "psutil 설치 완료 (~/.local)"
  read -rp "  oracledb 설치하시겠습니까? (Usage Tracking 사용 시 필요) [y/N]: " inst_db
  [[ "${inst_db,,}" == "y" ]] \
    && $PIP3 install --quiet --user oracledb && ok "oracledb 설치 완료 (~/.local)" \
    || info "oracledb 설치 건너뜀"
else
  err "pip 를 찾을 수 없습니다. 수동으로 설치하세요:"
  info "  pip3 install --user psutil oracledb"
fi

# ── Step 6: start.sh 생성 ─────────────────────────────────
hdr "Step 6 — start.sh 생성"

PID_FILE="$METRICS_INSTALL/oas-metrics.pid"

read -rp "  Usage Tracking DB 연결을 지금 설정하시겠습니까? [y/N]: " setup_ut
if [[ "${setup_ut,,}" == "y" ]]; then
  read -rp  "  OAS_UT_USER  (DB 계정): " UT_USER
  read -rsp "  OAS_UT_PASS  (비밀번호): " UT_PASS; echo ""
  read -rp  "  OAS_UT_DSN   (host:port/service): " UT_DSN
  read -rp  "  OAS_UT_TABLE (스키마.테이블명): " UT_TABLE
  UT_EXPORTS="export OAS_UT_USER=$UT_USER
export OAS_UT_PASS=$UT_PASS
export OAS_UT_DSN=$UT_DSN
export OAS_UT_TABLE=$UT_TABLE"
else
  UT_EXPORTS="# Usage Tracking DB 연결 — 사용 시 아래 주석을 해제하고 값을 입력하세요
# OAS Console → Advanced System Settings → Usage Tracking 에서 먼저 활성화 필요
# export OAS_UT_USER=<DB계정>
# export OAS_UT_PASS=<password>
# export OAS_UT_DSN=<host>:<port>/<service_name>
# export OAS_UT_TABLE=<스키마.테이블명>"
fi

cat > "$METRICS_INSTALL/start.sh" <<STARTSH
#!/bin/bash
export ORACLE_HOME=$ORACLE_HOME
export ORACLE_INSTANCE=$ORACLE_INSTANCE
export DOMAIN_HOME=$DOMAIN_HOME

$UT_EXPORTS

python3 $METRICS_INSTALL/metrics_server.py &
echo \$! > $PID_FILE
echo "[OAS Metrics] 기동 완료 (PID: \$!)"
STARTSH

chmod +x "$METRICS_INSTALL/start.sh"
ok "start.sh 생성: $METRICS_INSTALL/start.sh"

# ── Step 7: metrics_server.py 기동 ────────────────────────
hdr "Step 7 — metrics_server.py 기동"

if [[ -f "$PID_FILE" ]]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    info "기존 프로세스(PID=$OLD_PID) 종료"
    kill "$OLD_PID" && sleep 1
  fi
fi

"$METRICS_INSTALL/start.sh"
sleep 2

if curl -sf http://127.0.0.1:9091/metrics >/dev/null; then
  ok "metrics_server.py 응답 확인 (http://127.0.0.1:9091)"
else
  err "응답 없음. 수동으로 확인하세요:"
  err "  $PY3 $METRICS_INSTALL/metrics_server.py"
  exit 1
fi

# ── Step 8: OHS ProxyPass 설정 ────────────────────────────
hdr "Step 8 — OHS ProxyPass 설정"

PROXY_BLOCK="
# OAS Admin Dashboard — metrics proxy (배포 스크립트 자동 추가)
ProxyPass        /sysmgmt  http://localhost:9091
ProxyPassReverse /sysmgmt  http://localhost:9091"

if [[ ! -f "$OHS_CONF" ]]; then
  err "OHS httpd.conf 를 찾을 수 없습니다. 아래 내용을 수동으로 추가하세요:"
  echo "$PROXY_BLOCK"
elif grep -q "ProxyPass.*sysmgmt" "$OHS_CONF"; then
  ok "ProxyPass /sysmgmt 이미 설정되어 있습니다. 건너뜀"
else
  cp "$OHS_CONF" "${OHS_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  ok "기존 설정 백업 완료"
  printf '%s\n' "$PROXY_BLOCK" >> "$OHS_CONF"
  ok "ProxyPass 추가 완료: $OHS_CONF"
fi

# ── Step 9: OHS 재시작 ────────────────────────────────────
hdr "Step 9 — OHS 재시작"

read -rp "  OHS를 지금 재시작하시겠습니까? [y/N]: " restart_ohs
if [[ "${restart_ohs,,}" == "y" ]]; then
  OPMNCTL=$(command -v opmnctl || true)
  if [[ -n "$OPMNCTL" ]]; then
    "$OPMNCTL" restartproc ias-component="$OHS_COMPONENT"
    sleep 3
    if curl -sf "http://localhost:${OHS_PORT}/sysmgmt/metrics" >/dev/null; then
      ok "OHS 재시작 완료 — ProxyPass 동작 확인"
    else
      err "ProxyPass 응답 없음. OHS 설정 파일을 점검하세요: $OHS_CONF"
    fi
  else
    err "opmnctl 을 찾을 수 없습니다. 수동으로 재시작하세요:"
    info "  opmnctl restartproc ias-component=$OHS_COMPONENT"
  fi
else
  info "OHS 재시작을 건너뜁니다. 배포 후 아래 명령으로 재시작하세요:"
  info "  opmnctl restartproc ias-component=$OHS_COMPONENT"
fi

# ── 완료 ──────────────────────────────────────────────────
hdr "배포 완료"
ok "Option B 배포가 완료되었습니다."
echo ""
echo "  대시보드 접속: http://서버IP:${OHS_PORT}/oas-dashboard.html"
echo ""
echo "  설치 경로:"
echo "    스크립트 : $METRICS_INSTALL/"
echo "    스냅샷   : $BACKUP_INSTALL/"
echo ""
echo "  서버 관리:"
echo "    기동     : $METRICS_INSTALL/start.sh"
echo "    종료     : kill \$(cat $PID_FILE)"
echo "    상태확인 : curl http://127.0.0.1:9091/metrics"
echo ""
[[ "${setup_ut:-n}" != "y" ]] && \
  info "Usage Tracking 사용 시 $METRICS_INSTALL/start.sh 의 OAS_UT_* 환경변수를 설정 후 재기동하세요."
