# ADR-001 — Migration Strategy Decision
**Date:** 2025-03-20
**Author:** Cloud Migration Team
**Status:** Accepted

---

## To: CFO, CTO — Contoso Financial
## Re: Cloud Migration Strategy — Final Recommendation

---

### The Decision

We are recommending **lift-and-shift first, optimize in place after.**

We are not recommending a big-bang refactor on the way in.

---

### The Case

Contoso Financial has three workloads in scope:
- **Portal** — customer-facing web app, ~800 daily active users
- **Recon** — nightly batch reconciliation job, processes ~2M transactions
- **ReportDB** — shared reporting database, queried directly by 5 internal teams

These workloads are interdependent in ways that are only partially documented (see ADR-002). Attempting to refactor while migrating multiplies blast radius. A failure mid-refactor is a failure we cannot explain to regulators.

Lift-and-shift gives us:
- **Cloud cost visibility in 30 days**, not 6 months
- **A known-working baseline** in cloud before we change anything
- **Reversibility** — if something breaks post-migration, we know the diff is infrastructure, not code
- **CTO's cloud-native goals intact** — containerization and event-driven redesign happen in Phase 2, against a live cloud environment with real telemetry

The CFO gets the signed contract delivered. The CTO gets a credible Phase 2 roadmap with actual cloud metrics to justify the refactor spend.

---

### What We Are Accepting

| Risk | Mitigation |
|---|---|
| We pay for cloud + on-prem overlap during migration (~45 days) | Budgeted as transition cost; cheaper than a failed refactor |
| Lifted workloads are not yet cloud-optimised (over-provisioned VMs) | Reserved instance pricing applied from day 1; right-sizing in Phase 2 |
| ReportDB teams still query directly — no API layer yet | Read-replica promoted to cloud; connection strings updated, no schema change |
| Recon job still runs as a cron — not event-driven | Acceptable for Phase 1; event-driven redesign is Challenge 5, Phase 2 |

---

### What This Is Not

This is not a "lift and forget." Phase 2 begins 60 days post-cutover and targets:
- Containerise Portal → ECS/Cloud Run
- Recon → event-driven on S3/GCS file arrival
- ReportDB → managed RDS with API access layer, retire direct DB connections

Phase 2 is funded by the cost savings from right-sizing. It pays for itself.

---

### The Alternative We Rejected

Refactor-on-the-way-in was assessed and rejected. The primary reasons:

1. Two of three workloads have undocumented dependencies (see ADR-002). Refactoring without full discovery is archaeology under a deadline.
2. The CTO's vision is correct but the timeline is wrong. Cloud-native is the destination; it is not the migration vehicle.
3. Financial services regulators require a tested, signed-off cutover plan. A simultaneous migration + refactor cannot be rehearsed end-to-end.

---

### Decision

**Lift-and-shift. Phase 1 cutover in 45 days. Phase 2 begins day 60.**

No hedging. This is the call.
