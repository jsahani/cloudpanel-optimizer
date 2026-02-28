<div align="center">

# ⚡ CloudPanel Performance Optimizer

**One command to tune your CloudPanel VPS for production SaaS workloads.**

Auto-detects hardware, calculates optimal values, applies safe configurations — with full backup and rollback.

[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![CloudPanel](https://img.shields.io/badge/CloudPanel-2.x-0078D4)](https://www.cloudpanel.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## The Problem

A fresh CloudPanel VPS ships with conservative defaults designed for shared hosting — not for running production SaaS applications. Regardless of your server size, you'll typically see:

- **MySQL buffer pool** using only a fraction of available RAM
- **PHP-FPM pools** set to `ondemand` with cold-start delays
- **PHP memory_limit** set too high per process (wastefully reserving RAM)
- **No OPcache tuning** — recompiling PHP on every request
- **Redis** running without memory limits
- **Kernel** using default TCP and file descriptor settings

The result? TTFB of 1.5–3+ seconds, high CPU usage on MySQL, and a server that buckles under moderate traffic.

## The Solution

This script auto-detects your server specs and calculates optimal values — no manual tuning required. Works on any VPS size from 2GB to 128GB+.

```bash
sudo bash cloudpanel-optimize.sh
```

That's it. One command optimizes MySQL, PHP (all versions), PHP-FPM pools, Redis, and kernel settings.

---

## 🎯 What Gets Optimized

<table>
<tr>
<td width="50%" valign="top">

### MySQL / MariaDB
- InnoDB buffer pool sized to **20% of RAM**
- Buffer pool instances auto-scaled
- Connection limits tuned to CPU cores
- SSD-optimized I/O settings
- Slow query logging enabled

### PHP Global (all versions)
- `memory_limit` right-sized (256M default, 512M for ≥32GB servers)
- `max_execution_time` = 120s
- Upload limits = 64M
- `max_input_vars` = 5000

</td>
<td width="50%" valign="top">

### PHP-FPM Pools
- Switched from `ondemand` → `dynamic`
- `max_children` calculated per pool based on available RAM
- 20% warm `start_servers` (no cold starts)
- `listen.backlog` = 65535
- `rlimit_files` = 131072
- Per-pool OPcache reinforcement

### Redis
- `maxmemory` set to 10% of RAM (capped at 4GB)
- Eviction policy: `allkeys-lru`
- Persistence kept ON (safe for queues/sessions)
- TCP keepalive tuning

</td>
</tr>
</table>

### Kernel / Sysctl
- File descriptors raised to 2M
- TCP somaxconn & syn_backlog = 65535
- Swappiness reduced to 10
- Network buffers optimized to 16MB
- Process limits raised for `www-data`

---

## 📊 Expected Results

| Metric | Before | After | Improvement |
|--------|--------|-------|:-----------:|
| TTFB | 1.5 – 3.0s | 0.15 – 0.7s | **~85%** |
| MySQL CPU | 40 – 90% | 5 – 15% | **~80%** |
| PHP cold start delay | 1 – 3s | Eliminated | **100%** |
| PHP processes per site | 250+ (uncontrolled) | 20 – 150 (tuned) | **Controlled** |

---

## 🚀 Quick Start

### 1. Download

```bash
curl -O https://raw.githubusercontent.com/jsahani/cloudpanel-optimizer/main/cloudpanel-optimize.sh
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
sudo bash cloudpanel-optimize.sh              # Run full optimization
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
| **Full Backup** | Timestamped backup of all configs before any changes |
| **Config Validation** | Tests PHP-FPM and MySQL configs before restarting services |
| **Auto-Rollback** | If a service fails to start, configs are restored automatically |
| **Idempotent** | Safe to run multiple times — completed steps auto-skip |
| **Dry Run** | Preview every change without modifying anything |
| **Selective Restart** | Only restarts PHP-FPM versions with modified pools |

### Rollback

```bash
# Restore most recent backup
sudo bash cloudpanel-optimize.sh --rollback

# Restore a specific backup
sudo bash cloudpanel-optimize.sh --rollback /root/cp-backup-20260228-112931
```

---

## 🧮 How Values Are Calculated

All values are derived from your actual hardware specs — no hardcoded magic numbers. The script automatically scales to any server size.

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
```

### Example Profiles (auto-calculated)

**Small VPS — 4GB RAM / 2 Cores / 3 Sites:**
```
MySQL buffer pool    : 512M (1 instance)
MySQL max connections: 256
FPM max_children     : 20 per pool
Redis maxmemory      : 409mb
```

**Medium VPS — 16GB RAM / 4 Cores / 4 Sites:**
```
MySQL buffer pool    : 3G (3 instances)
MySQL max connections: 256
FPM max_children     : 40 per pool
Redis maxmemory      : 1638mb
```

**Large VPS — 48GB RAM / 12 Cores / 6 Sites:**
```
MySQL buffer pool    : 9G (9 instances)
MySQL max connections: 600
FPM max_children     : 80 per pool
Redis maxmemory      : 4096mb
```

---

## 📋 Recommended Deployment Workflow

```
┌─────────────────────────────────────┐
│  1. Provision fresh VPS             │
│  2. Install CloudPanel              │
│  3. Run optimizer (first pass)      │  ← MySQL, PHP global, Redis, kernel
│  4. Add your sites in CloudPanel    │
│  5. Run optimizer (second pass)     │  ← Optimizes new pools, skips the rest
│  6. Configure Redis in each .env    │
└─────────────────────────────────────┘
```

The script prints Redis credentials after optimization:

```
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=<your-password>
```

---

## ⚙️ Requirements

- **OS:** Ubuntu 22.04 / 24.04 (or any Debian-based distro)
- **Panel:** CloudPanel 2.x
- **RAM:** 2GB minimum (recommended 4GB+)
- **PHP:** 8.0+ (lower versions are auto-skipped)
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

All originals are backed up to `/root/cp-backup-YYYYMMDD-HHMMSS/` before modification.

---

## 🙏 Credits

Optimization strategies based on the comprehensive guide by [TVA.sg](https://www.tva.sg/cloudpanel-performance-optimization-maximizing-hetzner-cloud-server-performance-for-lightning-fast-website-delivery/), adapted and extended for multi-app SaaS deployments with auto-detection and safety features.

---

## 📄 License

[MIT](LICENSE) — Use it, fork it, improve it.
