#!/usr/bin/env python3
"""
OAS Dashboard - System Metrics & Snapshot HTTP Server
- Port 9091, localhost only (proxied via OHS)
- GET  /metrics   → JSON: cpu, memory, swap, disks
- GET  /version   → JSON: OAS 버전 자동 감지
- GET  /logs      → JSON: OAS 로그 파일 파싱 결과 (?file=obips&level=ERROR&lines=500)
- GET  /snapshots → JSON: 백업 디렉터리의 스냅샷 파일 목록
- POST /snapshot  → 백업 스크립트 실행 후 결과 반환
"""
import json
import glob
import os
import re
import subprocess
import threading
import psutil
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime

PORT = 9091
BIND = '127.0.0.1'   # OHS 프록시 사용: localhost 전용
                      # 직접 접근 원하면 '0.0.0.0' 으로 변경

# ── 백업 설정 (환경에 맞게 수정) ──────────────────────────
BACKUP_DIR    = '/u01/oas-backup/snapshots'
BACKUP_SCRIPT = '/u01/oas-scripts/oas-metrics/backup.sh'
# ─────────────────────────────────────────────────────────

# ── Usage Tracking DB 연결 설정 ───────────────────────────
# OAS Console → Advanced System Settings → Usage Tracking 에서 활성화 후 설정
# 환경변수로 주입하거나 아래 값을 직접 수정
DB_USER  = os.environ.get('OAS_UT_USER',  '')   # Usage Tracking DB 계정
DB_PASS  = os.environ.get('OAS_UT_PASS',  '')   # 비밀번호
DB_DSN   = os.environ.get('OAS_UT_DSN',   '')   # host:port/service_name
# OAS Console 에서 지정한 Logical Query Logging Table 의 실제 DB 테이블명
# 예) BIPLATFORM.S_NQ_ACCT (OBIEE 호환) 또는 실제 스키마.테이블명
DB_TABLE = os.environ.get('OAS_UT_TABLE', '')
# ─────────────────────────────────────────────────────────

# ── OAS 로그 파일 경로 (환경에 맞게 수정) ─────────────────
# ORACLE_INSTANCE 또는 환경변수에서 자동 감지되지 않을 경우 직접 지정
_OI = os.environ.get('ORACLE_INSTANCE', '')   # 예: /u01/oracle/config/OracleBIApplication/coreapplication
_DH = os.environ.get('DOMAIN_HOME',    '')    # 예: /u01/oracle/config/domains/bi

def _oi(*parts): return os.path.join(_OI, *parts) if _OI else ''
def _dh(*parts): return os.path.join(_DH, *parts) if _DH else ''

LOG_FILES = {
    'obips':    _oi('diagnostics','logs','OracleBIPresentationServicesComponent',
                    'coreapplication_obips1','sawlog0.log'),
    'nqserver': _oi('diagnostics','logs','OracleBIServerComponent',
                    'coreapplication_obis1','nqserver.log'),
    'nqquery':  _oi('diagnostics','logs','OracleBIServerComponent',
                    'coreapplication_obis1','nqquery.log'),
    'obisch':   _oi('diagnostics','logs','OracleBISchedulerComponent',
                    'coreapplication_obisch1','obisch1.log'),
    'domain':   _dh('servers','bi_server1','logs','bi_server1.log'),
    'admin':    _dh('servers','AdminServer','logs','AdminServer.log'),
    'ohs':      _oi('diagnostics','logs','OracleHTTPServer','ohs1','error_log'),
}
LOG_DEFAULT_LINES = 500
# ─────────────────────────────────────────────────────────


# ── 스냅샷 실행 상태 (단순 잠금) ──────────────────────────
_snap_lock   = threading.Lock()
_snap_status = {'running': False, 'last': None}   # last: {ok, msg, time}


def collect_metrics():
    cpu  = psutil.cpu_percent(interval=1)
    mem  = psutil.virtual_memory()
    swap = psutil.swap_memory()

    disks, seen = [], set()
    for part in psutil.disk_partitions(all=False):
        if part.mountpoint in seen:
            continue
        seen.add(part.mountpoint)
        try:
            u = psutil.disk_usage(part.mountpoint)
            disks.append({
                'mount':   part.mountpoint,
                'fstype':  part.fstype,
                'total':   u.total,
                'used':    u.used,
                'free':    u.free,
                'percent': round(u.percent, 1),
            })
        except PermissionError:
            pass

    return {
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'cpu':    {'percent': round(cpu, 1), 'count': psutil.cpu_count()},
        'memory': {'total': mem.total, 'used': mem.used,
                   'free': mem.available, 'percent': round(mem.percent, 1)},
        'swap':   {'total': swap.total, 'used': swap.used,
                   'free': swap.free, 'percent': round(swap.percent, 1)},
        'disks':  disks,
    }


def _db_connect():
    """python-oracledb(thin) 또는 cx_Oracle 중 설치된 드라이버 사용"""
    try:
        import oracledb
        conn = oracledb.connect(user=DB_USER, password=DB_PASS, dsn=DB_DSN)
        return conn, 'oracledb'
    except ImportError:
        pass
    try:
        import cx_Oracle
        conn = cx_Oracle.connect(DB_USER, DB_PASS, DB_DSN)
        return conn, 'cx_Oracle'
    except ImportError:
        raise RuntimeError('DB 드라이버 미설치. VM에서 실행: pip install oracledb')


def _row_to_dict(cursor, row):
    return {d[0].lower(): (v.isoformat() if hasattr(v, 'isoformat') else v)
            for d, v in zip(cursor.description, row)}


def get_usage_stats(period_days=90, top_n=20):
    """OAS LogicalQueries 테이블에서 사용량 통계 조회
    SUCCESS_FLG: 0=성공, 1=타임아웃, 2=행제한초과, 3=기타오류
    """
    if not DB_DSN or not DB_PASS or not DB_TABLE:
        return {
            'configured': False,
            'error': 'DB 연결 정보 미설정',
            'hint': ('OAS_UT_USER / OAS_UT_PASS / OAS_UT_DSN / OAS_UT_TABLE 환경변수를 설정하세요. '
                     'OAS Console → Advanced System Settings → Usage Tracking 에서 활성화 필요.'),
        }

    try:
        conn, driver = _db_connect()
    except Exception as e:
        return {'configured': True, 'error': f'DB 연결 실패: {e}'}

    try:
        cur = conn.cursor()
        tbl = DB_TABLE  # 관리자가 설정한 테이블명 (SQL injection 없음)

        # 1. 요약 통계
        cur.execute(f"""
            SELECT COUNT(*)                                           AS total_queries,
                   SUM(CASE WHEN SUCCESS_FLG != 0 THEN 1 ELSE 0 END) AS total_errors,
                   COUNT(DISTINCT USER_NAME)                          AS unique_users,
                   COUNT(DISTINCT SAW_SRC_PATH)                       AS unique_reports,
                   ROUND(AVG(TOTAL_TIME_SEC), 2)                      AS avg_sec
            FROM {tbl}
            WHERE START_TS >= SYSDATE - :days
        """, {'days': period_days})
        summary = _row_to_dict(cur, cur.fetchone())

        # 2. 가장 많이 사용된 리포트
        cur.execute(f"""
            SELECT SAW_SRC_PATH                                           AS path,
                   SAW_DASHBOARD                                          AS dashboard,
                   COUNT(*)                                               AS hit_count,
                   ROUND(AVG(TOTAL_TIME_SEC), 2)                         AS avg_sec,
                   ROUND(MAX(TOTAL_TIME_SEC), 2)                         AS max_sec,
                   COUNT(DISTINCT USER_NAME)                              AS unique_users,
                   SUM(CASE WHEN SUCCESS_FLG != 0 THEN 1 ELSE 0 END)      AS errors,
                   MAX(START_TS)                                          AS last_used
            FROM {tbl}
            WHERE START_TS >= SYSDATE - :days
              AND SAW_SRC_PATH IS NOT NULL
            GROUP BY SAW_SRC_PATH, SAW_DASHBOARD
            ORDER BY COUNT(*) DESC
            FETCH FIRST :n ROWS ONLY
        """, {'days': period_days, 'n': top_n})
        top_reports = [_row_to_dict(cur, r) for r in cur.fetchall()]

        # 3. 느린 리포트 (평균 응답시간 기준, 3회 이상 실행된 것만)
        cur.execute(f"""
            SELECT SAW_SRC_PATH                   AS path,
                   SAW_DASHBOARD                  AS dashboard,
                   ROUND(AVG(TOTAL_TIME_SEC), 2)  AS avg_sec,
                   ROUND(MAX(TOTAL_TIME_SEC), 2)  AS max_sec,
                   COUNT(*)                        AS hit_count
            FROM {tbl}
            WHERE START_TS >= SYSDATE - :days
              AND SUCCESS_FLG = 0
              AND SAW_SRC_PATH IS NOT NULL
              AND TOTAL_TIME_SEC > 0
            GROUP BY SAW_SRC_PATH, SAW_DASHBOARD
            HAVING COUNT(*) >= 3
            ORDER BY AVG(TOTAL_TIME_SEC) DESC
            FETCH FIRST 15 ROWS ONLY
        """, {'days': period_days})
        slow_reports = [_row_to_dict(cur, r) for r in cur.fetchall()]

        # 4. 상위 사용자
        cur.execute(f"""
            SELECT USER_NAME                      AS username,
                   COUNT(*)                       AS hit_count,
                   ROUND(AVG(TOTAL_TIME_SEC), 2)  AS avg_sec,
                   MAX(START_TS)                  AS last_access,
                   COUNT(DISTINCT SAW_SRC_PATH)   AS unique_reports
            FROM {tbl}
            WHERE START_TS >= SYSDATE - :days
            GROUP BY USER_NAME
            ORDER BY COUNT(*) DESC
            FETCH FIRST 15 ROWS ONLY
        """, {'days': period_days})
        top_users = [_row_to_dict(cur, r) for r in cur.fetchall()]

        # 5. 일별 쿼리 추이 (최근 30일)
        cur.execute(f"""
            SELECT TO_CHAR(TRUNC(START_TS), 'YYYY-MM-DD') AS day,
                   COUNT(*)                                AS total,
                   SUM(CASE WHEN SUCCESS_FLG != 0 THEN 1 ELSE 0 END) AS errors
            FROM {tbl}
            WHERE START_TS >= SYSDATE - 30
            GROUP BY TRUNC(START_TS)
            ORDER BY TRUNC(START_TS)
        """)
        daily_trend = [{'day': r[0], 'total': r[1], 'errors': r[2]}
                       for r in cur.fetchall()]

        # 6. Subject Area(주제 영역)별 사용 현황
        cur.execute(f"""
            SELECT SUBJECT_AREA_NAME              AS subject_area,
                   COUNT(*)                       AS hit_count,
                   COUNT(DISTINCT USER_NAME)      AS unique_users,
                   ROUND(AVG(TOTAL_TIME_SEC), 2)  AS avg_sec
            FROM {tbl}
            WHERE START_TS >= SYSDATE - :days
              AND SUBJECT_AREA_NAME IS NOT NULL
            GROUP BY SUBJECT_AREA_NAME
            ORDER BY COUNT(*) DESC
            FETCH FIRST 10 ROWS ONLY
        """, {'days': period_days})
        subject_areas = [_row_to_dict(cur, r) for r in cur.fetchall()]

        # 7. 최근 N일 내 사용된 경로 목록 (미사용 콘텐츠 감지용)
        cur.execute(f"""
            SELECT DISTINCT SAW_SRC_PATH
            FROM {tbl}
            WHERE START_TS >= SYSDATE - :days
              AND SAW_SRC_PATH IS NOT NULL
        """, {'days': period_days})
        used_paths = [r[0] for r in cur.fetchall()]

        return {
            'configured': True,
            'driver': driver,
            'period_days': period_days,
            'summary': summary,
            'topReports': top_reports,
            'slowReports': slow_reports,
            'topUsers': top_users,
            'dailyTrend': daily_trend,
            'subjectAreas': subject_areas,
            'usedPaths': used_paths,
        }
    except Exception as e:
        return {'configured': True, 'error': f'쿼리 실패: {e}'}
    finally:
        conn.close()


def tail_file(path, n=500):
    """파일 끝에서 n줄을 효율적으로 읽기 (수백 MB 파일도 빠름)"""
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            if size == 0:
                return []
            # 한 줄 평균 200 bytes로 추정, 부족하면 청크 확장
            chunk = min(n * 300, size)
            buf = b''
            pos = size
            while buf.count(b'\n') < n + 1 and pos > 0:
                read_size = min(chunk, pos)
                pos -= read_size
                f.seek(pos)
                buf = f.read(read_size) + buf
                chunk *= 2
            lines = buf.decode('utf-8', errors='replace').splitlines()
            return lines[-n:]
    except (OSError, IOError):
        return []


# ODL 형식: [timestamp] [component] [LEVEL] [] [logger] ... message
_ODL_RE = re.compile(
    r'^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[^\]]*)\]'  # timestamp
    r'\s+\[([^\]]*)\]'                                       # component
    r'\s+\[(ERROR|WARNING|WARN|NOTIFICATION|INCIDENT_ERROR|INFO|TRACE)[^\]]*\]'
    r'[^\]]*(?:\[[^\]]*\])*\s*(.*)'                          # message
)

# nqserver.log 형식: [PID] YYYY-MM-DD HH:MM:SS.mmm ZONE [LEVEL] ... message
_NQ_RE = re.compile(
    r'^\[\d+\]\s+'
    r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
    r'[^\[]*\[(ERROR|WARNING|WARN|NOTIFICATION|INFO|TRACE)[^\]]*\]'
    r'\s*(.*)'
)

# OHS error_log 형식: [Day Mon DD HH:MM:SS.mmm YYYY] [module:LEVEL] ... message
_OHS_RE = re.compile(
    r'^\[([^\]]+)\]\s+\[[^\]:]+:(error|warn|notice|info|debug)[^\]]*\]\s*(.*)',
    re.I
)

_LEVEL_MAP = {
    'INCIDENT_ERROR': 'ERROR',
    'WARN':           'WARNING',
    'NOTIFICATION':   'INFO',
    'NOTICE':         'INFO',
    'DEBUG':          'TRACE',
}

def _norm_level(lv):
    return _LEVEL_MAP.get(lv.upper(), lv.upper())


def parse_log_lines(lines, src_key):
    """로그 줄 목록을 [{t, lv, src, msg}] 형태로 파싱"""
    result = []
    pending_msg = None  # 멀티라인 연속 메시지 병합용

    for raw in lines:
        line = raw.strip()
        if not line:
            continue

        matched = None

        # ODL 형식 시도
        m = _ODL_RE.match(line)
        if m:
            ts, comp, lv, msg = m.group(1), m.group(2), m.group(3), m.group(4)
            # 타임스탬프를 읽기 쉬운 형태로 변환
            ts_short = ts[:19].replace('T', ' ')
            matched = {'t': ts_short, 'lv': _norm_level(lv),
                       'src': comp or src_key, 'msg': msg.strip()}

        # nqserver 형식 시도
        if not matched:
            m = _NQ_RE.match(line)
            if m:
                matched = {'t': m.group(1), 'lv': _norm_level(m.group(2)),
                           'src': src_key, 'msg': m.group(3).strip()}

        # OHS 형식 시도
        if not matched:
            m = _OHS_RE.match(line)
            if m:
                lv_raw = m.group(2).upper()
                matched = {'t': m.group(1)[:19], 'lv': _norm_level(lv_raw),
                           'src': 'ohs', 'msg': m.group(3).strip()}

        if matched:
            pending_msg = matched
            result.append(matched)
        elif pending_msg and line.startswith('\t'):
            # 들여쓰기 연속 줄 → 이전 메시지에 병합
            pending_msg['msg'] += ' | ' + line.strip()

    return result


def get_logs(file_key='obips', level_filter='', max_lines=LOG_DEFAULT_LINES):
    """지정한 로그 파일에서 최근 max_lines 줄을 읽어 파싱"""
    path = LOG_FILES.get(file_key)
    if not path:
        return {'error': f'알 수 없는 로그 파일 키: {file_key}',
                'availableKeys': list(LOG_FILES.keys())}
    if not os.path.exists(path):
        return {'error': f'로그 파일을 찾을 수 없습니다: {path}',
                'path': path, 'hint': 'ORACLE_INSTANCE / DOMAIN_HOME 환경변수를 확인하세요'}

    raw_lines = tail_file(path, max_lines)
    items = parse_log_lines(raw_lines, file_key)

    if level_filter:
        items = [i for i in items if i['lv'] == level_filter.upper()]

    file_size = os.path.getsize(path)
    mod_time  = datetime.fromtimestamp(os.path.getmtime(path)).isoformat()

    return {
        'file':     file_key,
        'path':     path,
        'fileSize': file_size,
        'lastModified': mod_time,
        'totalParsed':  len(items),
        'items':    list(reversed(items)),  # 최신 순
    }


def get_oas_version():
    """OAS/OBIEE 버전을 서버 파일 시스템에서 자동 감지"""
    oracle_home = os.environ.get('ORACLE_HOME', '')

    # 방법 1: OPatch lsinventory
    if oracle_home:
        opatch = os.path.join(oracle_home, 'OPatch', 'opatch')
        if os.path.exists(opatch):
            try:
                r = subprocess.run(
                    [opatch, 'lsinventory'],
                    capture_output=True, text=True, timeout=30, cwd='/'
                )
                for line in r.stdout.split('\n'):
                    for pat in [
                        r'Oracle Analytics[^\d]*(\d+\.\d+\.\d+\.\d+)',
                        r'Oracle Business Intelligence[^\d]*(\d+\.\d+\.\d+\.\d+)',
                    ]:
                        m = re.search(pat, line, re.I)
                        if m:
                            return {'version': m.group(1), 'source': 'OPatch lsinventory',
                                    'oracleHome': oracle_home}
            except Exception as e:
                pass

    # 방법 2: Oracle Inventory XML
    if oracle_home:
        inv = os.path.join(oracle_home, 'inventory', 'ContentsXML', 'comps.xml')
        if os.path.exists(inv):
            try:
                with open(inv, encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                m = re.search(r'Oracle Analytics[^"]*"[^"]*"[^"]*"(\d+\.\d+\.\d+\.\d+)"', content, re.I)
                if not m:
                    m = re.search(r'VER="(\d+\.\d+\.\d+\.\d+)"', content)
                if m:
                    return {'version': m.group(1), 'source': 'inventory/ContentsXML/comps.xml',
                            'oracleHome': oracle_home}
            except Exception:
                pass

    # 방법 3: domain-info.xml (DOMAIN_HOME)
    domain_home = os.environ.get('DOMAIN_HOME', '')
    if domain_home:
        vf = os.path.join(domain_home, 'domain-info.xml')
        if os.path.exists(vf):
            try:
                with open(vf, encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                m = re.search(r'<product-version>([^<]+)</product-version>', content)
                if m:
                    return {'version': m.group(1), 'source': 'domain-info.xml',
                            'domainHome': domain_home}
            except Exception:
                pass

    # 방법 4: bienv.sh 또는 setDomainEnv.sh 에서 버전 힌트 추출
    for search_path in [oracle_home, domain_home]:
        if not search_path:
            continue
        for fname in ['bienv.sh', 'bi-init.sh', 'setDomainEnv.sh']:
            fpath = os.path.join(search_path, 'bin', fname)
            if not os.path.exists(fpath):
                fpath = os.path.join(search_path, 'server', 'bin', fname)
            if os.path.exists(fpath):
                try:
                    with open(fpath, encoding='utf-8', errors='ignore') as f:
                        for line in f:
                            m = re.search(r'(\d+\.\d+\.\d+\.\d+)', line)
                            if m:
                                return {'version': m.group(1), 'source': fname,
                                        'file': fpath}
                except Exception:
                    pass

    return {
        'version': None,
        'source': None,
        'error': 'ORACLE_HOME/DOMAIN_HOME 환경변수 미설정 또는 버전 파일 없음',
        'oracleHome': oracle_home or '(미설정)',
        'domainHome': domain_home or '(미설정)',
    }


def list_snapshots():
    if not os.path.exists(BACKUP_DIR):
        return []
    files = []
    for pattern in ('*.bar', '*.tar.gz', '*.zip', '*.catalog'):
        files.extend(glob.glob(os.path.join(BACKUP_DIR, pattern)))
    result = []
    for f in sorted(files, key=os.path.getmtime, reverse=True):
        st = os.stat(f)
        result.append({
            'name':    os.path.basename(f),
            'size':    st.st_size,
            'created': datetime.fromtimestamp(st.st_mtime).isoformat(),
        })
    return result


def run_backup():
    """백업 스크립트를 별도 스레드에서 실행"""
    global _snap_status
    if not os.path.exists(BACKUP_SCRIPT):
        return False, f'백업 스크립트를 찾을 수 없습니다: {BACKUP_SCRIPT}'
    try:
        r = subprocess.run(
            ['/bin/bash', BACKUP_SCRIPT],
            capture_output=True, text=True, timeout=600
        )
        ok  = r.returncode == 0
        msg = (r.stdout or r.stderr or '').strip()
        return ok, msg
    except subprocess.TimeoutExpired:
        return False, '백업 스크립트 실행 시간 초과 (600초)'
    except Exception as e:
        return False, str(e)


def _run_backup_thread():
    global _snap_status
    ok, msg = run_backup()
    with _snap_lock:
        _snap_status['running'] = False
        _snap_status['last'] = {
            'ok':   ok,
            'msg':  msg,
            'time': datetime.now().isoformat(),
        }


def json_response(handler, data, status=200):
    body = json.dumps(data, ensure_ascii=False).encode()
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json; charset=utf-8')
    handler.send_header('Access-Control-Allow-Origin', '*')
    handler.send_header('Cache-Control', 'no-cache')
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.end_headers()

    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        path   = parsed.path.rstrip('/')
        params = parse_qs(parsed.query)

        def qp(key, default=''):
            return params.get(key, [default])[0]

        if path == '/metrics':
            try:
                json_response(self, collect_metrics())
            except Exception as e:
                json_response(self, {'error': str(e)}, 500)

        elif path == '/usage':
            try:
                period = int(qp('period', '90'))
                period = max(7, min(period, 365))
                top_n  = int(qp('top', '20'))
                json_response(self, get_usage_stats(period, top_n))
            except Exception as e:
                json_response(self, {'error': str(e)}, 500)

        elif path == '/logs':
            try:
                file_key = qp('file', 'obips')
                level    = qp('level', '')
                lines    = int(qp('lines', str(LOG_DEFAULT_LINES)))
                lines    = max(50, min(lines, 5000))
                json_response(self, get_logs(file_key, level, lines))
            except Exception as e:
                json_response(self, {'error': str(e)}, 500)

        elif path == '/version':
            try:
                json_response(self, get_oas_version())
            except Exception as e:
                json_response(self, {'error': str(e)}, 500)

        elif path == '/snapshots':
            try:
                items = list_snapshots()
                with _snap_lock:
                    status = dict(_snap_status)
                json_response(self, {'items': items, 'status': status,
                                     'backupDir': BACKUP_DIR})
            except Exception as e:
                json_response(self, {'error': str(e)}, 500)

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = self.path.rstrip('/')

        if path == '/snapshot':
            with _snap_lock:
                if _snap_status['running']:
                    json_response(self, {'ok': False, 'msg': '백업이 이미 실행 중입니다.'}, 409)
                    return
                _snap_status['running'] = True

            t = threading.Thread(target=_run_backup_thread, daemon=True)
            t.start()
            json_response(self, {'ok': True, 'msg': '백업을 시작했습니다. /snapshots 에서 진행 상황을 확인하세요.'})

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # 로그 억제


if __name__ == '__main__':
    server = HTTPServer((BIND, PORT), Handler)
    print(f'[OAS Metrics] 시작: http://{BIND}:{PORT}')
    print(f'  GET  /metrics   → 시스템 리소스')
    print(f'  GET  /usage     → Usage Tracking 통계 (?period=90&top=20)  [DB: {DB_DSN or "미설정"}, TABLE: {DB_TABLE or "미설정"}]')
    print(f'  GET  /version   → OAS 버전 자동 감지')
    print(f'  GET  /logs      → OAS 로그 파싱  (?file=obips&level=ERROR&lines=500)')
    print(f'  GET  /snapshots → 스냅샷 목록  (BACKUP_DIR: {BACKUP_DIR})')
    print(f'  POST /snapshot  → 스냅샷 생성  (SCRIPT: {BACKUP_SCRIPT})')
    print(f'  ORACLE_INSTANCE={_OI or "(미설정)"}')
    print(f'  DOMAIN_HOME    ={_DH or "(미설정)"}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n[OAS Metrics] 종료')
