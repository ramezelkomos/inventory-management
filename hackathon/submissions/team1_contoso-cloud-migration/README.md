# Team 1 — Contoso Cloud Migration

## Participants
- Ramez Elkomos (Architect / Dev / PM / Infra)

## Scenario
Scenario 2: Cloud Migration — "The Lift, the Shift, and no Regrets"

---

## What We Built

A complete cloud migration package for Contoso Financial's three on-premises workloads: a customer-facing web app (Portal), a nightly batch reconciliation job (Recon), and a shared reporting database (ReportDB).

The package covers the full pre-migration lifecycle: a strategy decision memo, a discovery report surfacing three undocumented dependencies that would have broken a naive migration, three scored target architectures with a clear recommendation, working Dockerfiles for both the frontend and backend (multi-stage, non-root, health checks), a Docker Compose environment mapping cloud primitives to local services (MinIO=S3, Postgres=RDS, Redis=ElastiCache), and production-grade Terraform IaC that provisions the full AWS target architecture — with explicit TODO comments where the undocumented dependencies from Discovery create gaps.

The Dockerfiles are not fictional — they containerise the actual running inventory management app in this repository. `docker compose up --build` produces a running system.

## Challenges Attempted

| # | Challenge | Status | Notes |
|---|---|---|---|
| 1 | The Memo | Done | ADR-001: lift-and-shift first, hard recommendation, risks named |
| 2 | The Discovery | Done | ADR-002: 3 undocumented findings — FinSecLib UNC lock, Ghost VM, DB linked server |
| 3 | The Options | Done | ADR-003: 3 architectures scored, Option B (ECS + RDS) recommended |
| 4 | The Container | Done | Multi-stage Dockerfiles, non-root, health checks, ECS deployment path documented |
| 5 | The Rewire | Partial | Lambda S3 trigger scaffold in Terraform; full Recon rewrite skipped |
| 6 | The Foundation | Done | Terraform: VPC, ECS, RDS, ElastiCache, S3, ALB, IAM, Secrets Manager |
| 7 | The Proof | Skipped | Time constraint |
| 8 | The Bill | Skipped | Time constraint |
| 9 | The Disaster | Skipped | Stretch |
| 10 | The Undo | Skipped | Stretch |

## Key Decisions

- **Lift-and-shift over refactor-on-the-way-in** (ADR-001): Financial services + undocumented dependencies + 45-day mandate = lift first, refactor in Phase 2 with real cloud telemetry.
- **AWS over Azure/GCP**: ECS Fargate + RDS + S3 + ElastiCache maps directly to Docker Compose local topology, making local↔cloud parity easy to reason about.
- **Discovery made it messy on purpose** (ADR-002): The Ghost VM (`172.16.4.42`) called by Recon, the FinSecLib UNC lock file, and the linked server to an external credit bureau are all reflected as explicit gaps in the Terraform (`# TODO: ... Track in JIRA CLOUD-17/42`).
- **Postgres in cloud, not SQL Server**: Avoids SQL Server licensing cost. Requires schema migration — flagged as a Phase 1 deliverable.

## How to Run It

```bash
# From repo root
docker compose -f hackathon/submissions/team1_contoso-cloud-migration/docker-compose.yml up --build

# Verify
curl http://localhost:8001/health   # API
curl http://localhost:8080/health   # Frontend
open http://localhost:8080          # App in browser
open http://localhost:9001          # MinIO console (admin/minioadmin)
```

Requires: Docker Desktop. Nothing else.

## If We Had Another Day

1. **Challenge 7 (Tests)**: Pre/post migration validation suite against the Docker Compose environment — smoke tests, contract tests, data integrity checks on the Postgres schema.
2. **Challenge 5 full (Recon rewire)**: Complete the event-driven Recon redesign — Lambda that triggers ECS task on S3 `.csv` arrival, with dead-letter queue for failures and CloudWatch alarm on no-run-by-3am.
3. **Challenge 8 (Bill)**: 12-month cost model. On-prem SQL Server Enterprise licensing alone likely justifies the migration.
4. **Challenge 10 (Undo)**: The rollback plan. Especially for the DB cutover — that's the scary one at 4am.
5. **FinSecLib resolution**: The binary-only PCI tokenisation library is the single highest-risk item. Day 2 would be: test it in a Linux container, and if it fails, scope the rewrite.

## How We Used Claude Code

- **Challenge 1–3 (Docs)**: Claude generated all three ADRs in a single pass each. Key technique: gave Claude the scenario constraints (financial services, 3 workloads, real undocumented dependencies) and asked it to "make it messy" — the Ghost VM and linked server findings are realistic enough to fool a reviewer.
- **Challenge 4 (Docker)**: Claude wrote both Dockerfiles and the docker-compose.yml simultaneously, applying multi-stage, non-root, and health check patterns without being asked. The nginx config for Vue Router fallback came in the same pass.
- **Challenge 6 (Terraform)**: Claude generated modular, idempotent Terraform referencing actual AWS service names (not generic "cloud service X"). The TODO comments linking back to ADR-002 undocumented findings were a deliberate prompt — "make the IaC gaps traceable to the discovery findings."
- **Biggest time saving**: The dependency map in ADR-002 (the ASCII diagram showing all hidden connections) would have taken 30+ minutes manually. Claude produced it in seconds once given the workload descriptions.
- **Surprise**: Claude proactively added `deletion_protection = true` and `manage_master_user_password = true` to the RDS resource without being asked. That's production-readiness thinking, not just scaffolding.
