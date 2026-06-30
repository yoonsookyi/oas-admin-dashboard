#!/bin/bash
# OAS 스냅샷 백업 스크립트
# metrics_server.py 의 POST /snapshot 에 의해 호출됨
# 환경에 맞게 경로 수정 필요

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backup/oas-snapshots"
DOMAIN_HOME="${DOMAIN_HOME:-/u01/oracle/config/domains/bi}"
ORACLE_INSTANCE="${ORACLE_INSTANCE:-/u01/oracle/config/OracleBIApplication/coreapplication}"

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
CATALOG_DIR="$ORACLE_INSTANCE/bifoundation/OracleBIPresentationServicesComponent/coreapplication_obips1/catalog"
if [ -d "$CATALOG_DIR" ]; then
    echo "[$(date)] 카탈로그 백업 중..."
    tar -czf "$BACKUP_DIR/catalog_${TIMESTAMP}.tar.gz" \
        "$CATALOG_DIR" 2>/dev/null
    echo "[$(date)] 카탈로그 백업 완료"
else
    echo "[$(date)] 경고: 카탈로그 디렉터리를 찾을 수 없습니다: $CATALOG_DIR"
fi

# ── 3. RPD 백업 ───────────────────────────────────────────
RPD_DIR="$ORACLE_INSTANCE/bifoundation/OracleBIServerComponent/coreapplication_obis1/repository"
if [ -d "$RPD_DIR" ]; then
    echo "[$(date)] RPD 백업 중..."
    cp -r "$RPD_DIR" "$BACKUP_DIR/rpd_${TIMESTAMP}" 2>/dev/null || true
    echo "[$(date)] RPD 백업 완료"
fi

# ── 4. 30일 이상 된 백업 정리 ─────────────────────────────
echo "[$(date)] 오래된 백업 정리 중 (30일 초과)..."
find "$BACKUP_DIR" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.bar" \) -mtime +30 -delete 2>/dev/null || true

echo "[$(date)] 백업 완료: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"/*${TIMESTAMP}* 2>/dev/null || true
