#!/bin/bash
# ============================================================================
#  CloudPanel Performance Optimizer v3.2
#  For SaaS / Multi-App VPS Deployments on CloudPanel
# ============================================================================
#
#  USAGE:
#    sudo bash cloudpanel-optimize.sh                # Auto-detect & optimize
#    sudo bash cloudpanel-optimize.sh --dry-run      # Preview all changes
#    sudo bash cloudpanel-optimize.sh --rollback     # Restore latest backup
#    sudo bash cloudpanel-optimize.sh --rollback /root/cp-backup-XXXXXXXX
#    sudo bash cloudpanel-optimize.sh --status       # Show current server health
#
# ============================================================================
#  CLOUDPANEL NOTE: Sites can use different PHP versions. This script scans
#  ALL /etc/php/*/fpm/pool.d/ directories and optimizes each version's pools
#  and php.ini independently.
# ============================================================================

set -u

# --- Configuration (auto-adjusted by detect_server_profile) ---
MYSQL_BUFFER_POOL=""
MYSQL_BUFFER_POOL_MB=0
MYSQL_BUFFER_INSTANCES=1
MYSQL_MAX_CONNECTIONS=256
MYSQL_TABLE_OPEN_CACHE=1024
PHP_MEMORY_LIMIT="256M"
FPM_MAX_CHILDREN=40
FPM_START_SERVERS=8
FPM_MIN_SPARE=4
FPM_MAX_SPARE=16
FPM_MAX_REQUESTS=1000
FPM_IDLE_TIMEOUT="300s"
REDIS_MAXMEMORY=""

# --- Runtime ---
DRY_RUN=false
BACKUP_DIR=""
MYSQL_CNF=""
TOTAL_RAM_MB=0
CPU_CORES=1
POOL_COUNT=0
SCRIPT_NAME="$(basename "$0")"
TOTAL_STEPS=7

# Arrays for multi-PHP support
declare -a ALL_PHP_VERSIONS=()       # Every PHP version installed
declare -a PHP_VERSIONS_WITH_POOLS=() # Only versions that have site pools
declare -a ALL_POOL_FILES=()          # Every site pool file found

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --- Helpers ---
log_info()   { echo -e "  ${BLUE}\u25b8${NC} $1"; }
log_ok()     { echo -e "  ${GREEN}\u2714${NC} $1"; }
log_warn()   { echo -e "  ${YELLOW}\u26a0${NC} $1"; }
log_err()    { echo -e "  ${RED}\u2716${NC} $1"; }
log_header() { echo -e "\n${CYAN}${BOLD}\u2500\u2500 $1 \u2500\u2500${NC}\n"; }
log_step()   { echo -e "\n${GREEN}${BOLD}[$1/$TOTAL_STEPS] $2${NC}\n"; }

# ============================================================================
# DETECTION
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Run as root: sudo bash $SCRIPT_NAME"
        exit 1
    fi
}

detect_system() {
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc 2>/dev/null || echo 2)
    TOTAL_RAM_MB=$(echo "$TOTAL_RAM_MB" | tr -dc '0-9')
    CPU_CORES=$(echo "$CPU_CORES" | tr -dc '0-9')
    if [[ -z "$TOTAL_RAM_MB" ]] || [[ "$TOTAL_RAM_MB" -eq 0 ]]; then TOTAL_RAM_MB=4096; fi
    if [[ -z "$CPU_CORES" ]] || [[ "$CPU_CORES" -eq 0 ]]; then CPU_CORES=2; fi
    log_info "Hardware: ${TOTAL_RAM_MB}MB RAM / ${CPU_CORES} CPU cores"
}

detect_all_php_versions() {
    ALL_PHP_VERSIONS=()
    local skipped=()
    for d in /etc/php/*/; do
        if [[ -d "$d" ]]; then
            local ver
            ver=$(basename "$d")
            local major
            major=$(echo "$ver" | cut -d. -f1)
            if [[ "$major" -lt 8 ]]; then
                skipped+=("$ver")
                continue
            fi
            ALL_PHP_VERSIONS+=("$ver")
        fi
    done

    if [[ ${#ALL_PHP_VERSIONS[@]} -eq 0 ]]; then
        log_err "No PHP 8.x+ versions found in /etc/php/"
        exit 1
    fi

    log_info "PHP versions (8.0+): ${ALL_PHP_VERSIONS[*]}"
    if [[ ${#skipped[@]} -gt 0 ]]; then
        log_info "Skipped (below 8.0): ${skipped[*]}"
    fi
}

detect_mysql_config() {
    MYSQL_CNF=""
    local candidates=(
        "/etc/mysql/mysql.conf.d/mysqld.cnf"
        "/etc/mysql/mariadb.conf.d/50-server.cnf"
        "/etc/mysql/my.cnf"
    )
    for path in "${candidates[@]}"; do
        if [[ -f "$path" ]]; then
            MYSQL_CNF="$path"
            break
        fi
    done
    if [[ -z "$MYSQL_CNF" ]]; then
        log_err "MySQL/MariaDB config not found"
        exit 1
    fi
    log_info "MySQL config: ${MYSQL_CNF}"
}

scan_all_pools() {
    POOL_COUNT=0
    ALL_POOL_FILES=()
    PHP_VERSIONS_WITH_POOLS=()

    local versions_seen=""

    for ver in "${ALL_PHP_VERSIONS[@]}"; do
        local pool_dir="/etc/php/${ver}/fpm/pool.d"
        if [[ ! -d "$pool_dir" ]]; then continue; fi

        for f in "$pool_dir"/*.conf; do
            if [[ ! -f "$f" ]]; then continue; fi
            local fname
            fname=$(basename "$f")
            case "$fname" in
                default*|global*|www.conf) continue ;;
            esac
            ALL_POOL_FILES+=("$f")
            POOL_COUNT=$((POOL_COUNT + 1))

            case "$versions_seen" in
                *"|${ver}|"*) ;;
                *)
                    PHP_VERSIONS_WITH_POOLS+=("$ver")
                    versions_seen="${versions_seen}|${ver}|"
                    ;;
            esac
        done
    done

    log_info "Website pools found: ${POOL_COUNT}"
    if [[ $POOL_COUNT -gt 0 ]]; then
        for pf in "${ALL_POOL_FILES[@]}"; do
            local rel_path="${pf#/etc/php/}"
            log_info "  \u2192 PHP ${rel_path}"
        done
        log_info "PHP versions with sites: ${PHP_VERSIONS_WITH_POOLS[*]}"
    fi
}

# ============================================================================
# SERVER PROFILE
# ============================================================================

detect_server_profile() {
    log_header "Server Profile Detection"

    detect_system
    detect_all_php_versions
    detect_mysql_config
    scan_all_pools

    local RAM_GB=$((TOTAL_RAM_MB / 1024))

    MYSQL_BUFFER_POOL_MB=$((TOTAL_RAM_MB * 20 / 100))
    MYSQL_BUFFER_POOL_MB=$(( (MYSQL_BUFFER_POOL_MB + 255) / 512 * 512 ))
    if [[ $MYSQL_BUFFER_POOL_MB -lt 512 ]]; then MYSQL_BUFFER_POOL_MB=512; fi

    if [[ $MYSQL_BUFFER_POOL_MB -ge 1024 ]]; then
        MYSQL_BUFFER_POOL="$((MYSQL_BUFFER_POOL_MB / 1024))G"
    else
        MYSQL_BUFFER_POOL="${MYSQL_BUFFER_POOL_MB}M"
    fi

    MYSQL_BUFFER_INSTANCES=$((MYSQL_BUFFER_POOL_MB / 1024))
    if [[ $MYSQL_BUFFER_INSTANCES -lt 1 ]]; then MYSQL_BUFFER_INSTANCES=1; fi
    if [[ $MYSQL_BUFFER_INSTANCES -gt 16 ]]; then MYSQL_BUFFER_INSTANCES=16; fi

    MYSQL_MAX_CONNECTIONS=$((CPU_CORES * 50))
    if [[ $MYSQL_MAX_CONNECTIONS -lt 256 ]]; then MYSQL_MAX_CONNECTIONS=256; fi
    if [[ $MYSQL_MAX_CONNECTIONS -gt 1024 ]]; then MYSQL_MAX_CONNECTIONS=1024; fi

    MYSQL_TABLE_OPEN_CACHE=$((MYSQL_MAX_CONNECTIONS * 4))
    if [[ $MYSQL_TABLE_OPEN_CACHE -gt 4096 ]]; then MYSQL_TABLE_OPEN_CACHE=4096; fi

    if [[ $RAM_GB -ge 32 ]]; then PHP_MEMORY_LIMIT="512M"; fi

    local SITES=$POOL_COUNT
    if [[ $SITES -lt 1 ]]; then SITES=6; fi

    local TOTAL_MAX_CHILDREN=$(( (TOTAL_RAM_MB * 50 / 100) / 50 ))
    FPM_MAX_CHILDREN=$((TOTAL_MAX_CHILDREN / SITES))
    if [[ $FPM_MAX_CHILDREN -lt 20 ]]; then FPM_MAX_CHILDREN=20; fi
    if [[ $FPM_MAX_CHILDREN -gt 150 ]]; then FPM_MAX_CHILDREN=150; fi

    FPM_START_SERVERS=$((FPM_MAX_CHILDREN * 20 / 100))
    if [[ $FPM_START_SERVERS -lt 4 ]]; then FPM_START_SERVERS=4; fi

    FPM_MIN_SPARE=$((FPM_START_SERVERS * 70 / 100))
    if [[ $FPM_MIN_SPARE -lt 2 ]]; then FPM_MIN_SPARE=2; fi

    FPM_MAX_SPARE=$((FPM_MAX_CHILDREN * 40 / 100))
    if [[ $FPM_MAX_SPARE -lt $FPM_START_SERVERS ]]; then FPM_MAX_SPARE=$FPM_START_SERVERS; fi

    if command -v redis-server &>/dev/null; then
        local REDIS_MB=$((TOTAL_RAM_MB * 10 / 100))
        if [[ $REDIS_MB -lt 128 ]]; then REDIS_MB=128; fi
        if [[ $REDIS_MB -gt 4096 ]]; then REDIS_MB=4096; fi
        REDIS_MAXMEMORY="${REDIS_MB}mb"
    fi

    local SITES_DISPLAY=$POOL_COUNT
    if [[ $SITES_DISPLAY -lt 1 ]]; then SITES_DISPLAY=6; fi

    echo ""
    echo -e "  ${BOLD}Computed Optimization Profile:${NC}"
    echo -e "  \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510"
    echo -e "  \u2502 MySQL buffer pool    : ${YELLOW}${MYSQL_BUFFER_POOL}${NC} (${MYSQL_BUFFER_INSTANCES} instances)"
    echo -e "  \u2502 MySQL max connections: ${YELLOW}${MYSQL_MAX_CONNECTIONS}${NC}"
    echo -e "  \u2502 MySQL table cache    : ${YELLOW}${MYSQL_TABLE_OPEN_CACHE}${NC}"
    echo -e "  \u2502 PHP memory_limit     : ${YELLOW}${PHP_MEMORY_LIMIT}${NC} (all versions)"
    echo -e "  \u2502 FPM max_children     : ${YELLOW}${FPM_MAX_CHILDREN}${NC} per pool"
    echo -e "  \u2502 FPM start_servers    : ${YELLOW}${FPM_START_SERVERS}${NC}"
    echo -e "  \u2502 FPM min/max spare    : ${YELLOW}${FPM_MIN_SPARE} / ${FPM_MAX_SPARE}${NC}"
    echo -e "  \u2502 FPM idle timeout     : ${YELLOW}${FPM_IDLE_TIMEOUT}${NC}"
    echo -e "  \u2502 FPM max requests     : ${YELLOW}${FPM_MAX_REQUESTS}${NC}"
    if [[ -n "$REDIS_MAXMEMORY" ]]; then
        echo -e "  \u2502 Redis maxmemory      : ${YELLOW}${REDIS_MAXMEMORY}${NC}"
    fi
    echo -e "  \u2502 Target pools         : ${YELLOW}${POOL_COUNT} found / ~${SITES_DISPLAY} estimated${NC}"
    echo -e "  \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518"
    echo ""
}

# ============================================================================
# STEP 1: BACKUP
# ============================================================================

create_backups() {
    log_step 1 "Full Config Backup"

    BACKUP_DIR="/root/cp-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"/{mysql,php,redis,nginx,system}

    cp -r /etc/mysql/ "$BACKUP_DIR/mysql/" 2>/dev/null && log_ok "MySQL configs" || log_warn "MySQL config copy issue"
    cp -r /etc/php/ "$BACKUP_DIR/php/" 2>/dev/null && log_ok "PHP configs (all versions)" || log_warn "PHP config copy issue"

    # Nginx -- backup main config and conf.d
    if [[ -f /etc/nginx/nginx.conf ]]; then
        cp /etc/nginx/nginx.conf "$BACKUP_DIR/nginx/" 2>/dev/null
        if [[ -d /etc/nginx/conf.d/ ]]; then
            cp -r /etc/nginx/conf.d/ "$BACKUP_DIR/nginx/conf.d/" 2>/dev/null
        fi
        log_ok "Nginx configs"
    fi

    local found_redis=false
    for rc in /etc/redis/redis.conf /etc/redis.conf; do
        if [[ -f "$rc" ]]; then
            cp "$rc" "$BACKUP_DIR/redis/"
            log_ok "Redis config"
            found_redis=true
            break
        fi
    done
    if [[ "$found_redis" == false ]]; then log_info "No Redis config found"; fi

    cp /etc/sysctl.conf "$BACKUP_DIR/system/" 2>/dev/null || true
    if [[ -d /etc/sysctl.d/ ]]; then cp -r /etc/sysctl.d/ "$BACKUP_DIR/system/" 2>/dev/null || true; fi
    log_ok "Sysctl configs"

    {
        echo "=== Backup: $(date) ==="
        echo "RAM: ${TOTAL_RAM_MB}MB | Cores: ${CPU_CORES}"
        echo "PHP versions: ${ALL_PHP_VERSIONS[*]}"
        echo "Pools found: ${POOL_COUNT}"
        if [[ ${#ALL_POOL_FILES[@]} -gt 0 ]]; then
            for pf in "${ALL_POOL_FILES[@]}"; do echo "  $pf"; done
        fi
        uname -a
        echo ""; echo "=== Memory ==="; free -h
        echo ""; echo "=== Disk ==="; df -h /
        echo ""; echo "=== Load ==="; uptime
        echo ""; echo "=== Services ==="
        echo "mysql: $(systemctl is-active mysql 2>/dev/null || systemctl is-active mariadb 2>/dev/null || echo unknown)"
        for ver in "${ALL_PHP_VERSIONS[@]}"; do
            echo "php${ver}-fpm: $(systemctl is-active "php${ver}-fpm" 2>/dev/null || echo inactive)"
        done
        echo "redis: $(systemctl is-active redis-server 2>/dev/null || echo not-running)"
        echo "nginx: $(systemctl is-active nginx 2>/dev/null || echo unknown)"
    } > "$BACKUP_DIR/system/state-before.txt" 2>/dev/null

    log_ok "System snapshot saved"
    log_ok "Backup dir: ${YELLOW}${BACKUP_DIR}${NC}"
}

# ============================================================================
# STEP 2: MYSQL
# ============================================================================

optimize_mysql() {
    log_step 2 "MySQL / MariaDB Optimization"

    if grep -q "# CP-OPTIMIZED" "$MYSQL_CNF" 2>/dev/null; then
        log_warn "Already optimized (CP-OPTIMIZED tag found). Skipping."
        log_info "To re-apply: rollback first, then run again."
        return
    fi

    local CONFIG_BLOCK="
# CP-OPTIMIZED $(date +%Y-%m-%d)
# Auto-generated for ${TOTAL_RAM_MB}MB RAM / ${CPU_CORES} cores

[mysqld]
# --- InnoDB Buffer Pool ---
innodb_buffer_pool_size = ${MYSQL_BUFFER_POOL}
innodb_buffer_pool_instances = ${MYSQL_BUFFER_INSTANCES}
innodb_io_capacity = 1000
innodb_io_capacity_max = 2000
innodb_flush_method = O_DIRECT
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1

# --- Connections ---
max_connections = ${MYSQL_MAX_CONNECTIONS}
thread_cache_size = $((CPU_CORES * 4))
table_open_cache = ${MYSQL_TABLE_OPEN_CACHE}
table_definition_cache = $((MYSQL_TABLE_OPEN_CACHE / 2))

# --- Memory Buffers ---
join_buffer_size = 8M
sort_buffer_size = 4M
read_buffer_size = 2M
read_rnd_buffer_size = 4M
tmp_table_size = 256M
max_heap_table_size = 256M

# --- Slow Query Log ---
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# --- Safety ---
max_allowed_packet = 64M
wait_timeout = 600
interactive_timeout = 600
"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would append to $MYSQL_CNF:"
        echo "$CONFIG_BLOCK"
        return
    fi

    echo "$CONFIG_BLOCK" >> "$MYSQL_CNF"
    log_ok "Config written to ${MYSQL_CNF}"

    mkdir -p /var/log/mysql
    chown mysql:mysql /var/log/mysql 2>/dev/null || true

    mysqld --validate-config 2>/dev/null && log_ok "Config validation passed" || log_info "Validation not available, proceeding"

    systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null || true
    sleep 2

    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
        log_ok "MySQL restarted successfully"
    else
        log_err "MySQL failed to start! Restoring backup..."
        cp -r "$BACKUP_DIR/mysql/"* /etc/mysql/ 2>/dev/null || true
        systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null || true
        log_warn "Rolled back MySQL config"
    fi
}

# ============================================================================
# STEP 3: PHP GLOBAL (all versions)
# ============================================================================

optimize_php_global() {
    log_step 3 "PHP Global Settings (all versions)"

    for ver in "${ALL_PHP_VERSIONS[@]}"; do
        local PHP_INI="/etc/php/${ver}/fpm/php.ini"

        if [[ ! -f "$PHP_INI" ]]; then
            continue
        fi

        if grep -q "CP-OPTIMIZED OPcache" "$PHP_INI" 2>/dev/null; then
            log_info "PHP ${ver}: already optimized, skipping"
            continue
        fi

        local CURRENT=""
        CURRENT=$(grep -E "^memory_limit\s*=" "$PHP_INI" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ') || true

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] PHP ${ver}: memory_limit ${CURRENT:-not set} \u2192 ${PHP_MEMORY_LIMIT}, + OPcache"
            continue
        fi

        sed -i "s/^memory_limit\s*=.*/memory_limit = ${PHP_MEMORY_LIMIT}/" "$PHP_INI"
        sed -i 's/^max_execution_time\s*=.*/max_execution_time = 120/' "$PHP_INI"
        sed -i 's/^max_input_time\s*=.*/max_input_time = 120/' "$PHP_INI"
        sed -i 's/^upload_max_filesize\s*=.*/upload_max_filesize = 64M/' "$PHP_INI"
        sed -i 's/^post_max_size\s*=.*/post_max_size = 64M/' "$PHP_INI"

        if grep -q "^max_input_vars" "$PHP_INI" 2>/dev/null; then
            sed -i 's/^max_input_vars\s*=.*/max_input_vars = 5000/' "$PHP_INI"
        else
            echo "max_input_vars = 5000" >> "$PHP_INI"
        fi

        cat >> "$PHP_INI" <<'OPCACHE'

; CP-OPTIMIZED OPcache
[opcache]
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.enable_cli=0
OPCACHE

        log_ok "PHP ${ver}: memory=${PHP_MEMORY_LIMIT}, OPcache configured"
    done

    if [[ "$DRY_RUN" != true ]]; then
        for ver in "${ALL_PHP_VERSIONS[@]}"; do
            if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
                if "php-fpm${ver}" -t 2>/dev/null; then
                    systemctl restart "php${ver}-fpm"
                    log_ok "php${ver}-fpm restarted"
                else
                    log_err "php${ver}-fpm config test failed! Restoring..."
                    cp "$BACKUP_DIR/php/php/${ver}/fpm/php.ini" "/etc/php/${ver}/fpm/php.ini" 2>/dev/null || true
                    systemctl restart "php${ver}-fpm" 2>/dev/null || true
                    log_warn "PHP ${ver} php.ini rolled back"
                fi
            fi
        done
    fi
}

# ============================================================================
# STEP 4: PHP-FPM POOLS (all versions)
# ============================================================================

optimize_php_pools() {
    log_step 4 "PHP-FPM Pool Optimization (all versions)"

    if [[ ${#ALL_POOL_FILES[@]} -eq 0 ]]; then
        log_warn "No website pools found in any PHP version."
        log_info "Add your apps in CloudPanel first, then re-run this script."
        log_info "MySQL, PHP global, Redis, Nginx & sysctl optimizations are already applied."
        return
    fi

    log_info "Optimizing ${#ALL_POOL_FILES[@]} pool(s) across ${#PHP_VERSIONS_WITH_POOLS[@]} PHP version(s)"
    log_info "Settings: max_children=${FPM_MAX_CHILDREN} per pool"

    update_or_add() {
        local key="$1" value="$2" file="$3"
        if grep -q "^${key}\s*=" "$file" 2>/dev/null; then
            sed -i "s|^${key}\s*=.*|${key} = ${value}|" "$file"
        else
            echo "${key} = ${value}" >> "$file"
        fi
    }

    local modified_versions=""

    for POOL_FILE in "${ALL_POOL_FILES[@]}"; do
        local POOL_NAME
        POOL_NAME=$(basename "$POOL_FILE" .conf)

        local PHP_VER
        PHP_VER=$(echo "$POOL_FILE" | sed 's|/etc/php/||;s|/fpm/pool.d/.*||')

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] Would optimize: ${POOL_NAME} (PHP ${PHP_VER})"
            continue
        fi

        if grep -q "; CP-OPTIMIZED\|# CP-OPTIMIZED" "$POOL_FILE" 2>/dev/null; then
            log_warn "${POOL_NAME} (PHP ${PHP_VER}) -- already optimized, skipping"
            continue
        fi

        sed -i 's/^pm\s*=\s*ondemand/pm = dynamic/' "$POOL_FILE"
        sed -i 's/^pm\s*=\s*static/pm = dynamic/' "$POOL_FILE"

        update_or_add "pm.max_children"          "$FPM_MAX_CHILDREN"  "$POOL_FILE"
        update_or_add "pm.start_servers"          "$FPM_START_SERVERS" "$POOL_FILE"
        update_or_add "pm.min_spare_servers"      "$FPM_MIN_SPARE"    "$POOL_FILE"
        update_or_add "pm.max_spare_servers"      "$FPM_MAX_SPARE"    "$POOL_FILE"
        update_or_add "pm.process_idle_timeout"   "$FPM_IDLE_TIMEOUT" "$POOL_FILE"
        update_or_add "pm.max_requests"           "$FPM_MAX_REQUESTS" "$POOL_FILE"
        update_or_add "request_terminate_timeout"  "300s"             "$POOL_FILE"

        update_or_add "listen.backlog"            "65535"             "$POOL_FILE"
        update_or_add "rlimit_files"              "131072"            "$POOL_FILE"
        update_or_add "catch_workers_output"      "yes"              "$POOL_FILE"

        if ! grep -q "opcache.enable" "$POOL_FILE" 2>/dev/null; then
            cat >> "$POOL_FILE" <<'POOLOPCACHE'

; Per-pool OPcache
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 20000
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 60
POOLOPCACHE
        fi

        if grep -q "php_admin_value\[memory_limit\]" "$POOL_FILE" 2>/dev/null; then
            sed -i "s|php_admin_value\[memory_limit\].*|php_admin_value[memory_limit] = ${PHP_MEMORY_LIMIT}|" "$POOL_FILE"
        else
            echo "php_admin_value[memory_limit] = ${PHP_MEMORY_LIMIT}" >> "$POOL_FILE"
        fi

        echo "" >> "$POOL_FILE"
        echo "; CP-OPTIMIZED $(date +%Y-%m-%d)" >> "$POOL_FILE"

        log_ok "${POOL_NAME} (PHP ${PHP_VER}) -- optimized"

        case "$modified_versions" in
            *"|${PHP_VER}|"*) ;;
            *) modified_versions="${modified_versions}|${PHP_VER}|" ;;
        esac
    done

    if [[ "$DRY_RUN" != true ]]; then
        sleep 1

        for ver in "${PHP_VERSIONS_WITH_POOLS[@]}"; do
            case "$modified_versions" in
                *"|${ver}|"*)
                    log_info "Testing php-fpm${ver} config..."
                    local test_output=""
                    local test_exit=0
                    test_output=$("php-fpm${ver}" -t 2>&1) || test_exit=$?

                    if [[ $test_exit -eq 0 ]]; then
                        systemctl restart "php${ver}-fpm"
                        log_ok "php${ver}-fpm config valid, restarted"
                    else
                        log_err "php${ver}-fpm config test FAILED (exit code: ${test_exit})"
                        log_err "Error output: ${test_output}"
                        log_info "Rolling back pools..."
                        cp "$BACKUP_DIR/php/php/${ver}/fpm/pool.d/"*.conf "/etc/php/${ver}/fpm/pool.d/" 2>/dev/null || true
                        systemctl restart "php${ver}-fpm" 2>/dev/null || true
                        log_warn "PHP ${ver} pool configs rolled back"
                    fi
                    ;;
            esac
        done
    fi
}

# ============================================================================
# STEP 5: REDIS
# ============================================================================

optimize_redis() {
    log_step 5 "Redis Optimization"

    if ! command -v redis-server &>/dev/null; then
        log_warn "Redis not installed -- skipping"
        return
    fi

    local REDIS_CONF=""
    for path in /etc/redis/redis.conf /etc/redis.conf; do
        if [[ -f "$path" ]]; then
            REDIS_CONF="$path"
            break
        fi
    done

    if [[ -z "$REDIS_CONF" ]]; then
        log_warn "Redis config not found -- skipping"
        return
    fi

    log_info "Redis config: $REDIS_CONF"

    if grep -q "# CP-OPTIMIZED" "$REDIS_CONF" 2>/dev/null; then
        log_warn "Already optimized. Skipping."
        show_redis_credentials "$REDIS_CONF"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would set maxmemory = ${REDIS_MAXMEMORY}"
        log_info "[DRY RUN] Would set maxmemory-policy = allkeys-lru"
        log_info "[DRY RUN] Would keep persistence ON (safe for queues)"
        show_redis_credentials "$REDIS_CONF"
        return
    fi

    redis_set() {
        local key="$1" value="$2"
        if grep -q "^${key} " "$REDIS_CONF" 2>/dev/null; then
            sed -i "s|^${key} .*|${key} ${value}|" "$REDIS_CONF"
        elif grep -q "^# *${key} " "$REDIS_CONF" 2>/dev/null; then
            sed -i "s|^# *${key} .*|${key} ${value}|" "$REDIS_CONF"
        else
            echo "${key} ${value}" >> "$REDIS_CONF"
        fi
    }

    redis_set "maxmemory"        "$REDIS_MAXMEMORY"
    redis_set "maxmemory-policy" "allkeys-lru"
    redis_set "tcp-keepalive"    "60"
    redis_set "timeout"          "300"

    echo "" >> "$REDIS_CONF"
    echo "# CP-OPTIMIZED $(date +%Y-%m-%d)" >> "$REDIS_CONF"

    systemctl restart redis-server 2>/dev/null || systemctl restart redis 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet redis-server 2>/dev/null || systemctl is-active --quiet redis 2>/dev/null; then
        log_ok "Redis: maxmemory = ${REDIS_MAXMEMORY}, policy = allkeys-lru"
        log_ok "Persistence kept ON (safe for queues/sessions)"
    else
        log_err "Redis failed to start! Restoring..."
        cp "$BACKUP_DIR/redis/"* "$(dirname "$REDIS_CONF")/" 2>/dev/null || true
        systemctl restart redis-server 2>/dev/null || systemctl restart redis 2>/dev/null || true
        log_warn "Redis config rolled back"
    fi

    show_redis_credentials "$REDIS_CONF"
}

show_redis_credentials() {
    local conf="$1"
    local REDIS_PASS=""
    REDIS_PASS=$(grep -E "^requirepass " "$conf" 2>/dev/null | awk '{print $2}') || true

    echo ""
    log_info "Redis credentials for your .env files:"
    echo -e "  ${CYAN}REDIS_HOST=${NC}127.0.0.1"
    echo -e "  ${CYAN}REDIS_PORT=${NC}6379"
    echo -e "  ${CYAN}REDIS_PASSWORD=${NC}${REDIS_PASS:-<none set>}"
    if [[ -z "$REDIS_PASS" ]]; then
        echo ""
        log_warn "No Redis password set. For SaaS apps, consider:"
        echo -e "  ${YELLOW}redis-cli CONFIG SET requirepass \"your-strong-password\"${NC}"
        echo -e "  ${YELLOW}Then add to $conf: requirepass your-strong-password${NC}"
    fi
}

# ============================================================================
# STEP 6: KERNEL / SYSCTL
# ============================================================================

optimize_sysctl() {
    log_step 6 "Kernel Network & File Tuning"

    local SYSCTL_FILE="/etc/sysctl.d/99-cloudpanel-optimize.conf"

    if [[ -f "$SYSCTL_FILE" ]]; then
        log_warn "Sysctl already optimized ($SYSCTL_FILE exists). Skipping."
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create $SYSCTL_FILE (TCP tuning, swappiness=10, file limits)"
        return
    fi

    cat > "$SYSCTL_FILE" <<'SYSCTL'
# CP-OPTIMIZED
# Safe kernel tuning for web/SaaS workloads

# File Descriptors
fs.file-max = 2097152

# TCP Performance
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Memory: Favor RAM over swap
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Network Buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
SYSCTL

    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

    local LIMITS_CONF="/etc/security/limits.d/99-cloudpanel-optimize.conf"
    if [[ ! -f "$LIMITS_CONF" ]]; then
        cat > "$LIMITS_CONF" <<'LIMITS'
# CP-OPTIMIZED file descriptor limits
* soft nofile 65535
* hard nofile 131072
www-data soft nproc 4096
www-data hard nproc 8192
LIMITS
        log_ok "File descriptor limits raised"
    fi

    log_ok "TCP optimization applied"
    log_ok "Swappiness set to 10"
    log_ok "Network buffers optimized"
}

# ============================================================================
# STEP 7: NGINX GLOBAL OPTIMIZATION
# ============================================================================
# NOTE: This ONLY modifies /etc/nginx/nginx.conf (main/events context) and
# creates /etc/nginx/conf.d/cloudpanel-optimize.conf (http context).
# It NEVER touches /etc/nginx/sites-enabled/* -- those are managed by CloudPanel.
# ============================================================================

optimize_nginx() {
    log_step 7 "Nginx Global Optimization"

    local NGINX_CONF="/etc/nginx/nginx.conf"
    local NGINX_OPT_CONF="/etc/nginx/conf.d/cloudpanel-optimize.conf"

    if [[ ! -f "$NGINX_CONF" ]]; then
        log_warn "Nginx config not found at $NGINX_CONF -- skipping"
        return
    fi

    # Check if already optimized
    if [[ -f "$NGINX_OPT_CONF" ]]; then
        log_warn "Already optimized ($NGINX_OPT_CONF exists). Skipping."
        return
    fi

    # --- Determine optimal values ---
    local WORKER_CONNECTIONS=65535
    local WORKER_RLIMIT=65535

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would update nginx.conf:"
        log_info "  worker_rlimit_nofile -> $WORKER_RLIMIT"
        log_info "  worker_connections   -> $WORKER_CONNECTIONS"
        log_info "[DRY RUN] Would create $NGINX_OPT_CONF with:"
        log_info "  Gzip compression (60-80% smaller responses)"
        log_info "  Keepalive optimization"
        log_info "  Client buffer tuning"
        log_info "  Open file cache"
        log_info "  Security headers (server_tokens off)"
        return
    fi

    local nginx_modified=false

    # --- Part 1: Update main/events context in nginx.conf ---

    # Raise worker_rlimit_nofile (CloudPanel default: 8192)
    if grep -q "^worker_rlimit_nofile" "$NGINX_CONF" 2>/dev/null; then
        local current_rlimit
        current_rlimit=$(grep "^worker_rlimit_nofile" "$NGINX_CONF" | awk '{print $2}' | tr -dc '0-9')
        if [[ -n "$current_rlimit" ]] && [[ "$current_rlimit" -lt "$WORKER_RLIMIT" ]]; then
            sed -i "s/^worker_rlimit_nofile.*/worker_rlimit_nofile ${WORKER_RLIMIT};/" "$NGINX_CONF"
            log_ok "worker_rlimit_nofile: ${current_rlimit} -> ${WORKER_RLIMIT}"
            nginx_modified=true
        else
            log_info "worker_rlimit_nofile already >= ${WORKER_RLIMIT}"
        fi
    else
        sed -i "/^worker_processes/a worker_rlimit_nofile ${WORKER_RLIMIT};" "$NGINX_CONF"
        log_ok "worker_rlimit_nofile: added (${WORKER_RLIMIT})"
        nginx_modified=true
    fi

    # Raise worker_connections (CloudPanel default: 2000)
    if grep -q "worker_connections" "$NGINX_CONF" 2>/dev/null; then
        local current_wc
        current_wc=$(grep "worker_connections" "$NGINX_CONF" | awk '{print $2}' | tr -dc '0-9')
        if [[ -n "$current_wc" ]] && [[ "$current_wc" -lt "$WORKER_CONNECTIONS" ]]; then
            sed -i "s/worker_connections.*/worker_connections ${WORKER_CONNECTIONS};/" "$NGINX_CONF"
            log_ok "worker_connections: ${current_wc} -> ${WORKER_CONNECTIONS}"
            nginx_modified=true
        else
            log_info "worker_connections already >= ${WORKER_CONNECTIONS}"
        fi
    fi

    # Enable multi_accept if commented out
    if grep -q "# *multi_accept on" "$NGINX_CONF" 2>/dev/null; then
        sed -i 's/# *multi_accept on/multi_accept on/' "$NGINX_CONF"
        log_ok "multi_accept: enabled"
        nginx_modified=true
    fi

    # --- Part 2: Create http-context drop-in config ---
    # This file is included via /etc/nginx/conf.d/*.conf which is inside the http {} block

    cat > "$NGINX_OPT_CONF" <<'NGINXOPT'
# CP-OPTIMIZED -- Nginx global performance tuning
# This file is auto-included via /etc/nginx/conf.d/ (http context)
# Safe for CloudPanel -- does NOT touch vhosts or sites-enabled

# --- Gzip Compression ---
# Reduces response sizes by 60-80% for text-based content
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types
    text/plain
    text/css
    text/javascript
    text/xml
    application/json
    application/javascript
    application/x-javascript
    application/xml
    application/xml+rss
    application/vnd.ms-fontobject
    application/x-font-ttf
    application/x-font-opentype
    font/opentype
    font/eot
    image/svg+xml
    image/x-icon;

# --- Keepalive Optimization ---
# Reuse connections instead of opening new ones for each request
keepalive_timeout 65;
keepalive_requests 1000;

# --- Client Buffer Tuning ---
# Reduce disk I/O for typical POST requests and headers
client_body_buffer_size 16k;
client_header_buffer_size 4k;
large_client_header_buffers 4 16k;

# --- tcp_nodelay ---
# Send small packets immediately (complements tcp_nopush already in nginx.conf)
tcp_nodelay on;

# --- Open File Cache ---
# Cache file metadata to avoid repeated disk lookups for static files
open_file_cache max=10000 inactive=60s;
open_file_cache_valid 30s;
open_file_cache_min_uses 2;
open_file_cache_errors on;

# --- Security ---
# Hide Nginx version from response headers
server_tokens off;

# --- Timeouts ---
# Reasonable timeouts to prevent resource exhaustion
send_timeout 30;
reset_timedout_connection on;
NGINXOPT

    log_ok "Created $NGINX_OPT_CONF"
    log_ok "  Gzip compression enabled (level 5)"
    log_ok "  Keepalive: 65s timeout, 1000 requests"
    log_ok "  Client buffers optimized"
    log_ok "  Open file cache: 10000 entries"
    log_ok "  server_tokens: off"

    # --- Validate and reload ---
    log_info "Testing nginx config..."
    local test_output=""
    local test_exit=0
    test_output=$(nginx -t 2>&1) || test_exit=$?

    if [[ $test_exit -eq 0 ]]; then
        systemctl reload nginx
        log_ok "Nginx config valid, reloaded"
    else
        log_err "Nginx config test FAILED (exit code: ${test_exit})"
        log_err "Error output: ${test_output}"
        log_info "Rolling back nginx changes..."

        # Restore nginx.conf from backup
        if [[ -f "$BACKUP_DIR/nginx/nginx.conf" ]]; then
            cp "$BACKUP_DIR/nginx/nginx.conf" "$NGINX_CONF" 2>/dev/null || true
        fi
        # Remove our drop-in config
        rm -f "$NGINX_OPT_CONF" 2>/dev/null || true

        systemctl reload nginx 2>/dev/null || true
        log_warn "Nginx changes rolled back"
    fi
}

# ============================================================================
# REPORT
# ============================================================================

show_report() {
    log_header "Optimization Complete"

    echo -e "  ${BOLD}Service Status:${NC}"
    printf "  %-20s %s\n" "MySQL/MariaDB:" "$(systemctl is-active mysql 2>/dev/null || systemctl is-active mariadb 2>/dev/null || echo unknown)"
    for ver in "${ALL_PHP_VERSIONS[@]}"; do
        local status
        status=$(systemctl is-active "php${ver}-fpm" 2>/dev/null) || status="inactive"
        if [[ "$status" == "active" ]]; then
            printf "  %-20s %s\n" "PHP-FPM ${ver}:" "$status"
        fi
    done
    printf "  %-20s %s\n" "Redis:" "$(systemctl is-active redis-server 2>/dev/null || systemctl is-active redis 2>/dev/null || echo not-running)"
    printf "  %-20s %s\n" "Nginx:" "$(systemctl is-active nginx 2>/dev/null || echo unknown)"
    if [[ -f /etc/nginx/conf.d/cloudpanel-optimize.conf ]]; then
        printf "  %-20s %s\n" "Nginx optimized:" "yes (gzip, keepalive, file cache)"
    fi
    echo ""

    echo -e "  ${BOLD}Resources:${NC}"
    free -h | awk '/^Mem:/ {printf "  RAM: %s used / %s total (%s free)\n", $3, $2, $4}'
    local fpm_count=0
    fpm_count=$(ps aux | grep -c "[p]hp-fpm" 2>/dev/null) || true
    printf "  PHP-FPM processes: %s\n" "$fpm_count"
    printf "  Load average: %s\n" "$(awk '{print $1, $2, $3}' /proc/loadavg)"
    echo ""

    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "  Backup dir   : ${YELLOW}${BACKUP_DIR}${NC}"
    echo -e "  Rollback     : ${CYAN}sudo bash $SCRIPT_NAME --rollback${NC}"
    echo -e "  Server health: ${CYAN}sudo bash $SCRIPT_NAME --status${NC}"
    echo ""

    echo -e "  ${BOLD}Test TTFB:${NC}"
    if [[ ${#ALL_POOL_FILES[@]} -gt 0 ]]; then
        for pf in "${ALL_POOL_FILES[@]}"; do
            local domain
            domain=$(basename "$pf" .conf)
            echo "  curl -w \"TTFB: %{time_starttransfer}s | Total: %{time_total}s\n\" -o /dev/null -s https://${domain}"
        done
    else
        echo '  curl -w "TTFB: %{time_starttransfer}s | Total: %{time_total}s\n" -o /dev/null -s https://your-site.com'
    fi
    echo ""

    if [[ $POOL_COUNT -eq 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}Next Steps:${NC}"
        echo -e "  ${YELLOW}1. Add your SaaS apps as websites in CloudPanel${NC}"
        echo -e "  ${YELLOW}2. Add Redis creds to each app's .env file${NC}"
        echo -e "  ${YELLOW}3. Re-run: sudo bash $SCRIPT_NAME${NC}"
        echo -e "  ${YELLOW}   (Already-done steps auto-skip, pools get optimized)${NC}"
        echo ""
    fi
}

# ============================================================================
# STATUS
# ============================================================================

show_status() {
    detect_system
    detect_all_php_versions
    scan_all_pools

    log_header "CloudPanel Server Health"

    echo -e "  ${BOLD}Hardware:${NC} ${TOTAL_RAM_MB}MB RAM / ${CPU_CORES} cores"
    echo ""

    echo -e "  ${BOLD}Memory:${NC}"
    free -h
    echo ""

    echo -e "  ${BOLD}Load:${NC}"
    uptime
    echo ""

    echo -e "  ${BOLD}Services:${NC}"
    printf "  %-20s %s\n" "MySQL:" "$(systemctl is-active mysql 2>/dev/null || systemctl is-active mariadb 2>/dev/null || echo unknown)"
    for ver in "${ALL_PHP_VERSIONS[@]}"; do
        local status
        status=$(systemctl is-active "php${ver}-fpm" 2>/dev/null) || status="inactive"
        printf "  %-20s %s\n" "PHP-FPM ${ver}:" "$status"
    done
    printf "  %-20s %s\n" "Redis:" "$(systemctl is-active redis-server 2>/dev/null || systemctl is-active redis 2>/dev/null || echo not-found)"
    printf "  %-20s %s\n" "Nginx:" "$(systemctl is-active nginx 2>/dev/null || echo unknown)"
    if [[ -f /etc/nginx/conf.d/cloudpanel-optimize.conf ]]; then
        printf "  %-20s %s\n" "Nginx optimized:" "yes (gzip, keepalive, file cache)"
    fi
    echo ""

    echo -e "  ${BOLD}Website Pools (${POOL_COUNT}):${NC}"
    if [[ ${#ALL_POOL_FILES[@]} -gt 0 ]]; then
        for pf in "${ALL_POOL_FILES[@]}"; do
            local pool_name php_ver
            pool_name=$(basename "$pf" .conf)
            php_ver=$(echo "$pf" | sed 's|/etc/php/||;s|/fpm/pool.d/.*||')
            printf "  %-35s PHP %s\n" "$pool_name" "$php_ver"
        done
    else
        echo "  None found"
    fi
    echo ""

    echo -e "  ${BOLD}PHP-FPM Processes by Pool:${NC}"
    local fpm_output
    fpm_output=$(ps aux 2>/dev/null | awk '/[p]hp-fpm: pool/ {print $NF}' | sort | uniq -c | sort -rn) || true
    if [[ -n "$fpm_output" ]]; then
        echo "$fpm_output" | head -10
    else
        echo "  None running"
    fi
    echo ""

    echo -e "  ${BOLD}Top Memory Consumers:${NC}"
    ps aux --sort=-%mem 2>/dev/null | awk 'NR>1 && NR<=8 {printf "  %-6s %s\n", $4"%", $11}'
    echo ""

    echo -e "  ${BOLD}MySQL Buffer Pool:${NC}"
    mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null || echo "  Cannot query (auth needed)"
    echo ""

    echo -e "  ${BOLD}Redis Memory:${NC}"
    local redis_info
    redis_info=$(redis-cli info memory 2>/dev/null) || true
    if [[ -n "$redis_info" ]]; then
        echo "$redis_info" | awk -F: '/used_memory_human|maxmemory_human/ {printf "  %s: %s\n", $1, $2}'
    else
        echo "  Not available"
    fi
    echo ""

    echo -e "  ${BOLD}Disk:${NC}"
    df -h / | awk 'NR==2 {printf "  %s used / %s total (%s available)\n", $3, $2, $4}'
    echo ""

    echo -e "  ${BOLD}Available Backups:${NC}"
    local backups
    backups=$(ls -dt /root/cp-backup-* 2>/dev/null | head -5) || true
    if [[ -n "$backups" ]]; then
        echo "$backups"
    else
        echo "  None"
    fi
    echo ""

    exit 0
}

# ============================================================================
# ROLLBACK
# ============================================================================

rollback() {
    detect_all_php_versions

    local RESTORE_DIR="${1:-}"
    if [[ -z "$RESTORE_DIR" ]]; then
        RESTORE_DIR=$(ls -dt /root/cp-backup-* 2>/dev/null | head -1) || true
        if [[ -z "$RESTORE_DIR" ]]; then
            log_err "No backup found. Usage: --rollback /root/cp-backup-XXXXXX"
            exit 1
        fi
    fi

    if [[ ! -d "$RESTORE_DIR" ]]; then
        log_err "Not found: $RESTORE_DIR"
        exit 1
    fi

    log_header "Rolling Back from ${RESTORE_DIR}"

    # MySQL
    if [[ -d "$RESTORE_DIR/mysql/mysql" ]]; then
        systemctl stop mysql 2>/dev/null || systemctl stop mariadb 2>/dev/null || true
        cp -r "$RESTORE_DIR/mysql/mysql/"* /etc/mysql/ 2>/dev/null || true
        systemctl start mysql 2>/dev/null || systemctl start mariadb 2>/dev/null || true
        log_ok "MySQL restored"
    fi

    # PHP -- restore all versions
    if [[ -d "$RESTORE_DIR/php/php" ]]; then
        cp -r "$RESTORE_DIR/php/php/"* /etc/php/ 2>/dev/null || true
        for ver in "${ALL_PHP_VERSIONS[@]}"; do
            if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
                systemctl restart "php${ver}-fpm" 2>/dev/null || true
                log_ok "php${ver}-fpm restored & restarted"
            fi
        done
    fi

    # Redis
    local restored_redis=false
    if [[ -f "$RESTORE_DIR/redis/redis.conf" ]]; then
        for path in /etc/redis/redis.conf /etc/redis.conf; do
            if [[ -f "$path" ]]; then
                cp "$RESTORE_DIR/redis/redis.conf" "$path"
                restored_redis=true
                break
            fi
        done
        if [[ "$restored_redis" == true ]]; then
            systemctl restart redis-server 2>/dev/null || systemctl restart redis 2>/dev/null || true
            log_ok "Redis restored"
        fi
    fi

    # Sysctl & limits
    rm -f /etc/sysctl.d/99-cloudpanel-optimize.conf 2>/dev/null || true
    rm -f /etc/security/limits.d/99-cloudpanel-optimize.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    log_ok "Sysctl & limits restored"

    # Nginx
    if [[ -f "$RESTORE_DIR/nginx/nginx.conf" ]]; then
        cp "$RESTORE_DIR/nginx/nginx.conf" /etc/nginx/nginx.conf 2>/dev/null || true
        log_ok "Nginx main config restored"
    fi
    rm -f /etc/nginx/conf.d/cloudpanel-optimize.conf 2>/dev/null || true
    if [[ -d "$RESTORE_DIR/nginx/conf.d" ]]; then
        cp -r "$RESTORE_DIR/nginx/conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true
    fi
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    log_ok "Nginx restored & reloaded"

    echo ""
    log_ok "Rollback complete. All configs restored."
    exit 0
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
    --rollback)  check_root; rollback "${2:-}" ;;
    --status)    check_root; show_status ;;
    --dry-run)   DRY_RUN=true ;;
    --help|-h)
        echo ""
        echo "  CloudPanel Performance Optimizer v3.2"
        echo ""
        echo "  Usage:"
        echo "    sudo bash $SCRIPT_NAME              Run full optimization"
        echo "    sudo bash $SCRIPT_NAME --dry-run     Preview all changes"
        echo "    sudo bash $SCRIPT_NAME --rollback    Restore latest backup"
        echo "    sudo bash $SCRIPT_NAME --status      Current server health"
        echo "    sudo bash $SCRIPT_NAME --help        This message"
        echo ""
        echo "  Scans ALL PHP versions for site pools (CloudPanel multi-PHP support)."
        echo "  Safe to run multiple times -- completed steps auto-skip."
        echo ""
        exit 0
        ;;
esac

check_root

echo ""
echo -e "${GREEN}${BOLD}\u2554\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2557${NC}"
echo -e "${GREEN}${BOLD}\u2551         CloudPanel Performance Optimizer v3.2                 \u2551${NC}"
echo -e "${GREEN}${BOLD}\u2551         Backup \u2192 Detect \u2192 Optimize \u2192 Verify                  \u2551${NC}"
echo -e "${GREEN}${BOLD}\u255a\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u255d${NC}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}${BOLD}DRY RUN MODE -- no changes will be made${NC}"
    echo ""
fi

detect_server_profile
create_backups
optimize_mysql
optimize_php_global
optimize_php_pools
optimize_redis
optimize_sysctl
optimize_nginx
show_report
