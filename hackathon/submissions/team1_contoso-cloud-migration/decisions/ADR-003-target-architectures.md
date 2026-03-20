# ADR-003 — Target Architecture Options
**Date:** 2025-03-20
**Author:** Cloud Migration Team
**Status:** Accepted
**Target Cloud:** AWS

---

## Option A — VM Lift-and-Shift (EC2)

Replicate on-prem topology in AWS. Each workload runs on EC2 instances behind a VPC. Minimal code changes.

| Workload | AWS Service |
|---|---|
| Portal | EC2 (Windows, t3.medium), IIS, behind ALB |
| Recon | EC2 (Linux, t3.small), cron preserved |
| ReportDB | EC2 (Windows, r5.large), SQL Server on EC2 |
| File shares | Amazon FSx for Windows File Server (replaces fileserver01) |
| SMTP | Amazon SES (replaces smtp01) |
| Auth | AWS Directory Service (AD Connector to on-prem AD, or Managed AD) |

**Score:**

| Criterion | Score (1–5) | Notes |
|---|---|---|
| Cost | 2 | SQL Server on EC2 is expensive; no managed service discount |
| Risk | 5 | Lowest migration risk; known topology |
| Speed | 5 | Fastest cutover — 30 days realistic |
| Operability | 2 | Still patching VMs; no auto-scaling; ops burden unchanged |

**Total: 14/20**

---

## Option B — Containers + Managed DB (Recommended)

Containerise Portal and Recon. Move ReportDB to RDS for SQL Server. Use S3 for file inputs, SES for email, ECS Fargate for compute.

| Workload | AWS Service |
|---|---|
| Portal | ECS Fargate (Docker container), behind ALB, Target Group health checks |
| Recon | ECS Fargate (scheduled task, replaces cron), triggered on S3 event via Lambda |
| ReportDB | Amazon RDS for SQL Server (Multi-AZ), replicate schemas |
| File inputs | S3 bucket (replaces NFS share on fileserver01) |
| FinSecLib lock files | S3 (mount via Mountpoint for S3 or EFS — to be validated) |
| SMTP | Amazon SES |
| Auth | Amazon Cognito (Portal auth) + IAM (service accounts) |
| Secrets | AWS Secrets Manager (replaces hardcoded IPs in web.config and run_recon.py) |

**Score:**

| Criterion | Score (1–5) | Notes |
|---|---|---|
| Cost | 4 | Fargate + RDS multi-AZ ~35% cheaper than equivalent EC2 at steady state |
| Risk | 3 | Containerisation adds migration complexity; mitigated by Phase 1 lift-first |
| Speed | 3 | 45–60 days to cutover |
| Operability | 5 | No VM patching; auto-scaling; managed DB backups; CloudWatch out of the box |

**Total: 15/20**

---

## Option C — Fully Cloud-Native (Serverless)

Maximum refactor. Portal becomes a React SPA + API Gateway + Lambda. Recon becomes an event-driven Step Functions workflow. ReportDB becomes Aurora Serverless.

| Workload | AWS Service |
|---|---|
| Portal | React SPA on S3/CloudFront + API Gateway + Lambda (Python/Node) |
| Recon | Step Functions + Lambda (event-driven, S3 trigger) |
| ReportDB | Aurora Serverless v2 (PostgreSQL) — requires schema migration from SQL Server |
| Auth | Amazon Cognito |
| Secrets | AWS Secrets Manager |

**Score:**

| Criterion | Score (1–5) | Notes |
|---|---|---|
| Cost | 5 | Serverless scales to zero; lowest year-2 cost |
| Risk | 1 | Full rewrite of Portal (.NET → Lambda) + SQL Server → Aurora schema migration = maximum blast radius |
| Speed | 1 | 4–6 months minimum; not viable for 45-day mandate |
| Operability | 5 | No servers to manage; fully managed |

**Total: 12/20**

---

## Recommendation

**Option B — Containers + Managed DB.**

Option A leaves Contoso paying EC2 + SQL Server licensing costs with no operational improvement. Option C is architecturally correct but violates the CFO's timeline and introduces unacceptable migration risk given the undocumented dependencies found in ADR-002.

Option B delivers:
- Containerised Portal and Recon (CTO's cloud-native goal, achieved in Phase 1)
- RDS replaces unmanaged SQL Server VM (backup, failover, patching — managed)
- Hardcoded IPs removed via Secrets Manager (fixes ADR-002 critical findings)
- FinSecLib UNC lock file dependency → EFS/S3 (mitigates highest-severity finding)
- Event-driven Recon via S3 trigger + Lambda (replaces fragile 2am cron)
- Ghost VM (`172.16.4.42`) decommissioned — call removed from Recon code
- Linked server to credit bureau → direct HTTPS call from application layer

### Phase 1 (Days 1–45): Option B infrastructure, lift Portal and Recon as containers
### Phase 2 (Days 60+): Event-driven Recon, session store (ElastiCache), API layer over ReportDB

---

## ADR Consequences

- `FinSecLib.dll` binary compatibility in a Linux container must be validated before cutover commitment. If it fails, Portal must run on Windows containers (ECS supports this) or the tokenisation component must be rewritten. **This is the single highest-risk item in the migration.**
- The linked server to `creditcheck.ext.contoso.com` must be replaced with an application-layer API call. DBA and dev team to agree interface before Phase 1 cutover.
- BI team direct SQL connections to ReportDB will continue post-migration (RDS endpoint replaces EC2 endpoint). API abstraction layer is Phase 2.
