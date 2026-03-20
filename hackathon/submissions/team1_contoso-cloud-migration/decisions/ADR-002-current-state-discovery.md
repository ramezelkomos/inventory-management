# ADR-002 — Current State Discovery
**Date:** 2025-03-20
**Author:** Cloud Migration Team
**Status:** Accepted

---

## Contoso Financial — On-Premises Workload Inventory

### Discovery Method
- Interviews with 4 engineers (2 dev, 1 ops, 1 DBA)
- Network scan of prod VLAN (172.16.4.0/24)
- Config file audit on app servers
- Batch log analysis (90 days)

---

## Workload 1 — Portal (Customer Web App)

| Property | Value |
|---|---|
| Host | `app01.contoso.internal` (172.16.4.10) |
| OS | Windows Server 2016 |
| Runtime | .NET Framework 4.7.2 |
| Web server | IIS 10 |
| App | `C:\inetpub\contoso-portal\` |
| Sessions | Stored in-process (no external session store) |
| Config | `web.config` with DB connection string **hardcoded to 172.16.4.33** |
| Dependencies | SQL Server on `172.16.4.33`, SMTP relay on `172.16.4.5` |
| Deployment | Manual xcopy from dev laptop. No CI/CD. |
| Auth | Windows Authentication via on-prem Active Directory |
| Known issues | Session loss on IIS restart. Vendor library `FinSecLib.dll` — **no source, no vendor contact, binary only.** |

### Undocumented Finding
`FinSecLib.dll` (v2.1.3, last modified 2019) is a proprietary binary with no source code and no vendor support. It handles PCI-DSS tokenisation. It writes a lock file to `\\fileserver01\finlib-locks\` (UNC path, `172.16.4.20`). **This UNC dependency is not in any architecture doc.** If the lock share is unavailable, Portal silently fails card tokenisation — no error surfaced to the user.

---

## Workload 2 — Recon (Nightly Batch Reconciliation)

| Property | Value |
|---|---|
| Host | `batch01.contoso.internal` (172.16.4.15) |
| OS | Ubuntu 20.04 |
| Runtime | Python 3.8 |
| Scheduler | cron — `0 2 * * *` (2:00 AM AEST) |
| Script | `/opt/recon/run_recon.py` |
| Input | CSV files dropped to `/mnt/sftp-inbound/` (NFS mount from `172.16.4.20`) |
| Output | Writes reconciliation summary **directly to ReportDB** (`recon_results` schema) |
| Dependencies | NFS share on `172.16.4.20`, ReportDB on `172.16.4.33` |
| Retry logic | None. If the job fails, it does not retry. Ops is paged at 6am if the output table is empty. |
| Known issues | Job runtime has grown from 4 min (2021) to 47 min (2025) as transaction volume grew. No optimisation since original author left. |

### Undocumented Finding
`run_recon.py` contains a hardcoded IP for a **secondary validation service**: `requests.get("http://172.16.4.42/api/validate")`. This host (`172.16.4.42`) does not appear in the CMDB. Network scan confirms it is a **decommissioned VM that still responds on port 80** — serving a stale validation endpoint. The Recon job calls it on every run; it is not clear whether the response is actually used. Code comment says `# TODO: remove after Dec 2022`.

---

## Workload 3 — ReportDB (Shared Reporting Database)

| Property | Value |
|---|---|
| Host | `db01.contoso.internal` (172.16.4.33) |
| OS | Windows Server 2019 |
| Engine | SQL Server 2017 Enterprise |
| Size | 380 GB (data), 12 GB (logs) |
| Schemas | `dbo` (app), `recon_results` (batch), `rpt_*` (5 reporting schemas, one per team) |
| Consumers | Portal (app reads/writes `dbo`), Recon (writes `recon_results`), 5 BI teams (direct SQL connections with individual AD service accounts) |
| Backup | SQL Server Agent job, full backup nightly to `\\fileserver01\db-backups\` |
| Recovery | Last tested: **never.** Backup files exist. Restoration process is undocumented. |
| Known issues | Two BI teams use `rpt_finance` schema with cross-schema JOINs into `dbo`. Direct dependency, no abstraction. |

### Undocumented Finding
The `rpt_dataops` schema contains a **linked server** definition pointing to a third-party credit bureau at `creditcheck.ext.contoso.com:1433`. This linked server is used in one stored procedure (`sp_daily_credit_refresh`) called by a scheduled SQL Agent job. **This is an undocumented external network dependency from inside the DB server.** It will break silently post-migration unless the linked server DNS and firewall rules are replicated in the cloud environment.

---

## Shared Infrastructure

| Resource | Host | IP | Role |
|---|---|---|---|
| File Server | `fileserver01.contoso.internal` | 172.16.4.20 | NFS + CIFS shares (NFS for Recon input, CIFS for FinSecLib locks, DB backups) |
| SMTP Relay | `smtp01.contoso.internal` | 172.16.4.5 | Outbound email for Portal alerts |
| Active Directory | `dc01.contoso.internal` | 172.16.4.2 | Auth for Portal, SQL Server logins for BI teams |
| Ghost VM | *(unnamed)* | 172.16.4.42 | Decommissioned. Still running. Called by Recon. |

---

## Dependency Map

```
Portal (172.16.4.10)
  └── SQL Server (172.16.4.33)         [hardcoded in web.config]
  └── SMTP Relay (172.16.4.5)
  └── fileserver01 UNC share (172.16.4.20)  ← UNDOCUMENTED (FinSecLib lock file)
  └── Active Directory (172.16.4.2)

Recon (172.16.4.15)
  └── NFS share on fileserver01 (172.16.4.20)   [input CSVs]
  └── SQL Server (172.16.4.33)         [writes recon_results]
  └── Ghost VM (172.16.4.42)           ← UNDOCUMENTED (hardcoded validation call)

ReportDB (172.16.4.33)
  └── fileserver01 CIFS share (172.16.4.20)  [backups]
  └── creditcheck.ext.contoso.com:1433       ← UNDOCUMENTED (linked server, external)
  └── Active Directory (172.16.4.2)    [BI team service accounts]
```

---

## Migration Risk Summary

| Finding | Severity | Blocks Migration? |
|---|---|---|
| `FinSecLib.dll` — binary, no source, UNC lock dependency | **HIGH** | Yes — must validate binary runs in container + replace UNC with cloud file share |
| Ghost VM `172.16.4.42` called by Recon | **HIGH** | Yes — must determine if response is used; decommission or replicate |
| ReportDB linked server to external credit bureau | **HIGH** | Yes — firewall + DNS must be replicated; SQL Agent job must be migrated |
| Portal DB connection hardcoded to on-prem IP | **MEDIUM** | Yes — replace with environment variable / cloud DNS before cutover |
| Recon has no retry logic | **MEDIUM** | No — operational risk, address in Phase 2 |
| DB restoration never tested | **MEDIUM** | No — test restore in cloud as part of Challenge 7 |
| Portal uses in-process sessions | **LOW** | No — acceptable for Phase 1 lift; Redis session store in Phase 2 |
