#!/bin/bash
# OAS 스냅샷 백업 스크립트
# metrics_server.py 의 POST /snapshot 에 의해 호출됨
# 환경에 맞게 경로 수정 필요

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/u01/oas-backup/oas-snapshots"
# OAS(FMW 기반): 모든 런타임 데이터는 DOMAIN_HOME 아래에 있음
DOMAIN_HOME="${DOMAIN_HOME:-/u01/data/domains/bi}"

mkdir -p "$BACKUP_DIR"

echo "[$(date)] 백업 시작: $TIMESTAMP"

# ── 1. WebLogic 도메인 설정 백업 ──────────────────────────
echo "[$(date)] 도메인 설정 백업 중..."
tar -czf "$BACKUP_DIR/domain_config_${TIMESTAMP}.tar.gz" \
    --exclude="$DOMAIN_HOME/servers/*/tmp" \
    --exclude="$DOMAIN_HOME/servers/*/logs" \
    "$DOMAIN_HOME/config" 2>/dev/null || true
echo "[$(date)] 도메인 설정 백업 완료"

# ── 2. OAS 카탈로그 백업 ──────────────────────────────────
# OAS 카탈로그 위치: DOMAIN_HOME/diagnostics/logs 기준 또는 bidata 경로
# bidata 경로가 있으면 우선 사용, 없으면 대체 경로 탐색
CATALOG_DIR=""
for _c in \
  "$DOMAIN_HOME/bidata/service_instances/ssi/OracleBIDataRoot/OracleBIPresentationServicesComponent/catalog" \
  "$DOMAIN_HOME/config/BIInstance/data/OracleBIPresentationServicesComponent/catalog"; do
  [ -d "$_c" ] && CATALOG_DIR="$_c" && break
done

if [ -n "$CATALOG_DIR" ]; then
    echo "[$(date)] 카탈로그 백업 중: $CATALOG_DIR"
    tar -czf "$BACKUP_DIR/catalog_${TIMESTAMP}.tar.gz" \
        "$CATALOG_DIR" 2>/dev/null
    echo "[$(date)] 카탈로그 백업 완료"
else
    echo "[$(date)] 경고: 카탈로그 디렉터리를 찾을 수 없습니다 (DOMAIN_HOME=$DOMAIN_HOME)"
fi

# ── 3. RPD 백업 ───────────────────────────────────────────
RPD_DIR=""
for _r in \
  "$DOMAIN_HOME/bidata/service_instances/ssi/OracleBIDataRoot/OracleBIServerComponent/repository" \
  "$DOMAIN_HOME/config/BIInstance/data/OracleBIServerComponent/repository"; do
  [ -d "$_r" ] && RPD_DIR="$_r" && break
done

if [ -n "$RPD_DIR" ]; then
    echo "[$(date)] RPD 백업 중: $RPD_DIR"
    cp -r "$RPD_DIR" "$BACKUP_DIR/rpd_${TIMESTAMP}" 2>/dev/null || true
    echo "[$(date)] RPD 백업 완료"
else
    echo "[$(date)] 경고: RPD 디렉터리를 찾을 수 없습니다 (DOMAIN_HOME=$DOMAIN_HOME)"
fi

# ── 4. 30일 이상 된 백업 정리 ─────────────────────────────
echo "[$(date)] 오래된 백업 정리 중 (30일 초과)..."
find "$BACKUP_DIR" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.bar" \) -mtime +30 -delete 2>/dev/null || true

echo "[$(date)] 백업 완료: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"/*${TIMESTAMP}* 2>/dev/null || true
