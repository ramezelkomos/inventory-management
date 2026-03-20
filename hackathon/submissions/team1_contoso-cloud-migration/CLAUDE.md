# CLAUDE.md — Contoso Cloud Migration

This submission implements Scenario 2 (Cloud Migration) of the APAC Claude Code Hackathon.

## Purpose

Cloud migration package for Contoso Financial's three on-prem workloads to AWS. Produces cloud-ready artifacts that run locally with production-equivalent architecture using Docker Compose.

## Key Files

| File | Role |
|---|---|
| `decisions/ADR-001-migration-strategy.md` | Strategy decision: lift-and-shift first |
| `decisions/ADR-002-current-state-discovery.md` | Current state + 3 undocumented dependency findings |
| `decisions/ADR-003-target-architectures.md` | 3 options scored; Option B (ECS + RDS) recommended |
| `decisions/ADR-004-container-deployment.md` | Docker build + ECS deployment path |
| `Dockerfile.backend` | Multi-stage Python/FastAPI image (non-root, health check) |
| `Dockerfile.frontend` | Multi-stage Node/nginx image (non-root, health check) |
| `nginx.conf` | nginx config for Vue Router SPA + health endpoint |
| `docker-compose.yml` | Full local environment (backend, frontend, MinIO, Postgres, Redis) |
| `terraform/main.tf` | AWS IaC: VPC, ECS, RDS, ElastiCache, S3, ALB, Lambda, IAM |
| `terraform/variables.tf` | Input variables (no hardcoded values) |
| `terraform/security_groups.tf` | Least-privilege security groups |

## Local Cloud Primitives Mapping

| Local Service | Cloud Equivalent | Purpose |
|---|---|---|
| MinIO | Amazon S3 | Recon input CSVs, FinSecLib lock files |
| Postgres | Amazon RDS (SQL Server migrated) | ReportDB |
| Redis | Amazon ElastiCache | Session store (Phase 2) |
| ECS (local Docker) | AWS ECS Fargate | Portal + Recon compute |

## Commands

```bash
# Run full local environment
docker compose -f hackathon/submissions/team1_contoso-cloud-migration/docker-compose.yml up --build

# Run from submission directory
docker compose up --build

# Verify health
curl http://localhost:8001/health
curl http://localhost:8080/health

# Terraform (dry run)
cd terraform
terraform init
terraform plan -var="aws_account_id=123456789012" -var="acm_certificate_arn=arn:aws:acm:..."
```

## Conventions

- All ADRs in `decisions/` directory, numbered sequentially
- Terraform: no hardcoded secrets, all sensitive values via `aws_secretsmanager_secret`
- Docker: multi-stage builds, non-root users, health checks on all containers
- Discovery gaps from ADR-002 are explicitly referenced as `# TODO` comments in Terraform
- The Dockerfiles containerise the actual running app in this repo (not fictional)

## Undocumented Findings (ADR-002) — Key Context

Three findings found in discovery that complicate the IaC and must be resolved before cutover:

1. **FinSecLib.dll** — PCI tokenisation binary with UNC lock file dependency (`\\fileserver01\finlib-locks\`). Replaces with S3 bucket + Mountpoint. Binary Linux compatibility unvalidated. Tracked: JIRA CLOUD-17.
2. **Ghost VM `172.16.4.42`** — Decommissioned VM still called by Recon. Call must be removed/redirected before migration. Tracked: JIRA CLOUD-33.
3. **ReportDB linked server** — SQL Server linked server to `creditcheck.ext.contoso.com:1433`. Cannot be replicated in RDS. Must be replaced with application-layer API call. Tracked: JIRA CLOUD-42.
