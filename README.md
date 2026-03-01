<div align="center">

# ⚡ CloudPanel Performance Optimizer

**One command to tune your CloudPanel VPS for production SaaS workloads.**

Auto-detects hardware, calculates optimal values, applies safe configurations — with full backup and rollback.

Works on any VPS size from 2GB to 128GB+.

[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![CloudPanel](https://img.shields.io/badge/CloudPanel-2.x-0078D4)](https://www.cloudpanel.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## The Problem

A fresh CloudPanel VPS ships with conservative defaults designed for shared hosting — not for running production SaaS applications. You'll typically see:

- **MySQL buffer pool** using only a fraction of available RAM
- **PHP-FPM pools** set to `ondemand` with cold-start delays
- **PHP memory_limit** at 768M per process (wastefully high)
- **No OPcache tuning** — recompiling PHP on every request
- **Redis** running without memory limits
- **Nginx** serving uncompressed responses with low connection limits
- **Kernel** using default TCP and file descriptor settings

The result? TTFB of 1.5–3+ seconds, high CPU usage on MySQL, and a server that buckles under moderate traffic.

## The Solution

This script auto-detects your server specs and calculates optimal values — no manual tuning required.

```bash
sudo bash cloudpanel-optimize.sh
```

That's it. One command runs all 7 optimization steps: MySQL, PHP (all versions), PHP-FPM pools, Redis, kernel, and Nginx global tuning.

### Auto-Scaling Examples

| Server | MySQL Buffer Pool | FPM max_children | Redis |
|--------|:-----------------:|:----------------:|:-----:|
| 4GB / 2 cores | 512M | 20/pool | 128mb |
| 16GB / 4 cores | 3G | 40/pool | 1024mb |
| 48GB / 12 cores | 9G | 80/pool | 4096mb |

---

## 🎯 What Gets Optimized (7 Steps)

<table>
<tr>
<td width="50%" valign="top">

### Step 2: MySQL / MariaDB
- InnoDB buffer pool sized to **20% of RAM**
- Buffer pool instances auto-scaled
- Connection limits tuned to CPU cores
- SSD-optimized I/O settings
- Slow query logging enabled

### Step 3: PHP Global (all versions)
- `memory_limit` right-sized (512M for ≥32GB servers)
- `max_execution_time` = 120s
- Upload limits = 64M
- `max_input_vars` = 5000
- Full OPcache configuration

### Step 4: PHP-FPM Pools
- Switched from `ondemand` → `dynamic`
- `max_children` calculated per pool
- 20% warm `start_servers` (no cold starts)
- `listen.backlog` = 65535
- `rlimit_files` = 131072
- Per-pool OPcache reinforcement

</td>
<td width="50%" valign="top">

### Step 5: Redis
- `maxmemory` set to 10% of RAM (capped at 4GB)
- Eviction policy: `allkeys-lru`
- Persistence kept ON (safe for queues/sessions)
- TCP keepalive tuning

### Step 6: Kernel / Sysctl
- File descriptors raised to 2M
- TCP somaxconn & syn_backlog = 65535
- Swappiness reduced to 10
- Network buffers optimized to 16MB
- Process limits raised for `www-data`

### Step 7: Nginx Global
- **Gzip compression** (60-80% smaller responses)
- `worker_connections` raised to 65535
- `worker_rlimit_nofile` raised to 65535
- `multi_accept` enabled
- Open file cache (10,000 entries)
- Keepalive optimization (65s, 1000 req)
- Client buffer tuning
- `server_tokens off` (security)
- **Safe:** only touches `nginx.conf` + `/etc/nginx/conf.d/` — never modifies CloudPanel vhosts

</td>
</tr>
</table>

> **Step 1** is always a full config backup before any changes are made.

---

## 📊 Expected Results

| Metric | Before | After | Improvement |
|--------|--------|-------|:-----------:|
| TTFB | 1.5 – 3.0s | 0.15 – 0.7s | **~85%** |
| Response size (text) | 100% | 20 – 40% | **60-80% smaller** |
| MySQL CPU | 40 – 90% | 5 – 15% | **~80%** |
| Free RAM (48GB server) | 2 – 4 GB | 8 – 12 GB | **~3x** |
| PHP cold start delay | 1 – 3s | Eliminated | **100%** |
| PHP processes per site | 250+ (uncontrolled) | 20 – 150 (tuned) | **Controlled** |

---

## 🚀 Quick Start

### 1. Download

```bash
curl -O https://raw.githubusercontent.com/jsahani/cloudpanel-optimizer/main/cloudpanel-optimize.sh
chmod +x cloudpanel-optimize.sh
```

### 2. Preview (Dry Run)

```bash
sudo bash cloudpanel-optimize.sh --dry-run
```

### 3. Apply

```bash
sudo bash cloudpanel-optimize.sh
```

### 4. Verify

```bash
sudo bash cloudpanel-optimize.sh --status
```

---

## 📖 Usage

```
sudo bash cloudpanel-optimize.sh              # Run full optimization (7 steps)
sudo bash cloudpanel-optimize.sh --dry-run     # Preview all changes
sudo bash cloudpanel-optimize.sh --rollback    # Restore latest backup
sudo bash cloudpanel-optimize.sh --status      # Current server health
sudo bash cloudpanel-optimize.sh --help        # Show usage
```

---

## 🔄 Multi-PHP Version Support

CloudPanel lets each site use a different PHP version. This script handles that automatically — it scans **all** `/etc/php/*/fpm/pool.d/` directories and optimizes each version's pools and `php.ini` independently.

```
── Server Profile Detection ──
  ▸ PHP versions (8.0+): 8.0 8.1 8.2 8.3 8.4 8.5
  ▸ Website pools found: 3
  ▸   → PHP 8.3/fpm/pool.d/app.example.com.conf
  ▸   → PHP 8.4/fpm/pool.d/api.example.com.conf
  ▸   → PHP 8.5/fpm/pool.d/dashboard.example.com.conf
```

PHP versions below 8.0 are automatically skipped.

---

## 🛡️ Safety Features

| Feature | Description |
|---------|-------------|
| **Full Backup** | Timestamped backup of all configs (MySQL, PHP, Redis, Nginx, sysctl) |
| **Auto-Cleanup** | Only the 3 most recent backups are kept — older ones are pruned automatically on each run |
| **Config Validation** | Tests PHP-FPM, MySQL, and Nginx configs before restarting services |
| **Auto-Rollback** | If a service fails to start or `nginx -t` fails, configs are restored automatically |
| **Idempotent** | Safe to run multiple times — completed steps auto-skip |
| **Dry Run** | Preview every change without modifying anything |
| **Selective Restart** | Only restarts PHP-FPM versions with modified pools |
| **CloudPanel Safe** | Never touches `/etc/nginx/sites-enabled/*` — vhosts remain CloudPanel-managed |

### Rollback

```bash
# Restore most recent backup
sudo bash cloudpanel-optimize.sh --rollback

# Restore a specific backup
sudo bash cloudpanel-optimize.sh --rollback /root/cp-backup-20260228-112931
```

---

## 🧮 How Values Are Calculated

All values are derived from your actual hardware specs — no hardcoded magic numbers.

```
MySQL buffer pool     = RAM × 20%
Buffer pool instances = buffer_pool_GB (max 16)
Max connections       = CPU_cores × 50 (min 256, max 1024)
Table cache           = max_connections × 4

PHP memory_limit      = 512M (≥32GB RAM) or 256M
FPM max_children      = (RAM × 50% / 50MB) / number_of_sites
FPM start_servers     = max_children × 20%
FPM min_spare         = start_servers × 70%
FPM max_spare         = max_children × 40%

Redis maxmemory       = RAM × 10% (max 4GB)

Nginx worker_connections  = 65535
Nginx worker_rlimit       = 65535
Nginx gzip_comp_level     = 5
Nginx open_file_cache     = 10000 entries
```

### Example: 48GB RAM / 12 Cores / 6 Sites

```
MySQL buffer pool    : 9G (9 instances)
MySQL max connections: 600
FPM max_children     : 80 per pool
FPM start_servers    : 16
Redis maxmemory      : 4096mb
Nginx gzip           : on (level 5)
Nginx connections    : 65535
```

---

## 📋 Recommended Deployment Workflow

```
┌─────────────────────────────────────┐
│  1. Provision fresh VPS             │
│  2. Install CloudPanel              │
│  3. Run optimizer (first pass)      │  ← MySQL, PHP, Redis, kernel, Nginx
│  4. Add your sites in CloudPanel    │
│  5. Run optimizer (second pass)     │  ← Optimizes new pools, skips the rest
│  6. Configure Redis in each .env    │
│  7. Enable HTTP/3 per site (UI)     │  ← CloudPanel Vhost Editor toggle
└─────────────────────────────────────┘
```

The script prints Redis credentials after optimization:

```
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=<your-password>
```

### Per-Site: Enable HTTP/3

HTTP/3 is a per-site setting managed through CloudPanel's UI (not this script):

1. Go to your site in CloudPanel → **Vhost Editor**
2. Change `http3 off;` to `http3 on;`
3. Ensure UDP port 443 is open in your firewall
4. Requires a valid Let's Encrypt certificate (not self-signed)

---

## ⚙️ Requirements

- **OS:** Ubuntu 22.04 / 24.04 (or any Debian-based distro)
- **Panel:** CloudPanel 2.x
- **PHP:** 8.0+ (lower versions are auto-skipped)
- **RAM:** 2GB minimum (recommended 4GB+)
- **Access:** Root (`sudo`)
- **Disk:** SSD recommended (I/O settings are SSD-optimized)

---

## 🗂️ Files Modified

| File | What Changes |
|------|-------------|
| `/etc/mysql/my.cnf` (or equivalent) | InnoDB, connections, buffers, logging |
| `/etc/php/*/fpm/php.ini` | memory_limit, execution time, OPcache |
| `/etc/php/*/fpm/pool.d/*.conf` | PM mode, children, spare servers, backlog |
| `/etc/redis/redis.conf` | maxmemory, eviction policy, keepalive |
| `/etc/sysctl.d/99-cloudpanel-optimize.conf` | TCP, swappiness, file descriptors |
| `/etc/security/limits.d/99-cloudpanel-optimize.conf` | nofile, nproc limits |
| `/etc/nginx/nginx.conf` | worker_rlimit_nofile, worker_connections, multi_accept |
| `/etc/nginx/conf.d/cloudpanel-optimize.conf` | Gzip, keepalive, buffers, file cache, server_tokens |

**Not modified:** `/etc/nginx/sites-enabled/*` — CloudPanel vhosts are never touched.

All originals are backed up to `/root/cp-backup-YYYYMMDD-HHMMSS/` before modification. Only the 3 most recent backups are retained.

---

## 📄 License

[MIT](LICENSE) — Use it, fork it, improve it.
