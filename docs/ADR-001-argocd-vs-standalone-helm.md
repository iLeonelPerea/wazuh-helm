# ADR-001: ArgoCD + Helm vs Standalone Helm for Stateful Workloads

**Status:** Accepted
**Date:** 2026-03-29
**Deciders:** Leonel Perea (Platform Engineering Lead)

## Context

Kamet runs EKS Auto Mode clusters (dev and prod) deploying both stateful infrastructure (Wazuh SIEM, HashiCorp Vault, OpenSearch) and stateless application workloads (Alebrije microservices, dashboards, APIs).

The question arose whether ArgoCD should manage Helm chart deployments, including stateful workloads like Wazuh, or whether standalone Helm (`helm upgrade`) remains the better approach for certain workload types.

### Forces at play

- **GitOps adoption**: The team is evaluating ArgoCD for declarative, Git-driven deployments.
- **Stateful complexity**: Wazuh uses 3-node OpenSearch StatefulSets with PVCs, ordered startup chains, and a security init container that runs `securityadmin.sh`.
- **EKS Auto Mode constraints**: Karpenter node consolidation and CoreDNS as systemd introduce fragility — aggressive automation increases blast radius.
- **Small team**: 1 platform engineer managing infrastructure across 2 clusters. Operational simplicity matters.

## Decision

**Use standalone Helm (`helm upgrade`) for stateful infrastructure workloads.** Reserve ArgoCD for stateless application deployments where GitOps provides clear value without the risks associated with stateful reconciliation.

### Workload classification

| Workload Type | Deployment Method | Examples |
|---|---|---|
| Stateful infrastructure | Standalone Helm (`helm upgrade`) | Wazuh, Vault, OpenSearch, ESO |
| Stateless applications | ArgoCD (candidate) | Alebrije microservices, dashboards, APIs |
| Cluster addons | Managed by EKS / Terraform | CoreDNS, kube-proxy, Karpenter |

## Options Considered

### Option A: ArgoCD for Everything (Including Stateful)

| Dimension | Assessment |
|-----------|------------|
| Complexity | **High** — requires redesigning charts for idempotency, hook conversion, PVC exception handling |
| Cost | Low (ArgoCD is OSS) |
| Scalability | Good for multi-cluster |
| Team familiarity | Low — team currently uses Helm CLI |
| Risk to data | **High** — auto-prune can delete PVCs, auto-sync can re-run security init |

**Pros:**
- Single pane of glass for all deployments
- Git as source of truth for everything
- Automatic drift detection and reconciliation
- Multi-cluster deployments via ApplicationSet

**Cons:**
- ArgoCD uses `helm template` + `kubectl apply`, NOT `helm install/upgrade` — no Helm release tracking, `helm list` shows nothing
- `.Release.IsInstall` / `.Release.IsUpgrade` are always false — breaks conditional logic in charts
- `lookup()` function returns empty (no API server access during template rendering)
- Helm hooks (`pre-install`, `pre-upgrade`) all execute on every sync — `securityadmin.sh` would re-run every time
- StatefulSet PVCs marked as "OutOfSync" constantly; PVC resize changes are silently ignored
- Auto-prune could delete PVCs and cause data loss
- Rollback is Git-based, not `helm rollback` — different mental model
- Small team overhead: maintaining ArgoCD itself becomes another stateful workload to manage

### Option B: Standalone Helm for Everything

| Dimension | Assessment |
|-----------|------------|
| Complexity | **Low** — current approach, team knows it well |
| Cost | Zero |
| Scalability | Manual — requires SSH/kubectl per cluster |
| Team familiarity | High |
| Risk to data | Low — explicit `helm upgrade` with manual review |

**Pros:**
- Full Helm lifecycle (install vs upgrade distinction works)
- Hooks execute at correct stages
- `helm list`, `helm history`, `helm rollback` all work
- PVC management is predictable
- No additional infrastructure to maintain
- Current workflow is validated and documented

**Cons:**
- No automatic drift detection
- No GitOps — deployments are imperative
- Multi-cluster requires manual repetition
- No centralized deployment visibility

### Option C: Hybrid (Chosen)

| Dimension | Assessment |
|-----------|------------|
| Complexity | **Medium** — two deployment methods, clear boundary |
| Cost | Low (ArgoCD only for stateless) |
| Scalability | Good for stateless, manual for stateful |
| Team familiarity | Medium — gradual ArgoCD adoption |
| Risk to data | **Low** — stateful workloads stay on proven path |

**Pros:**
- Stateful workloads keep full Helm lifecycle safety
- Stateless apps get GitOps benefits (auto-sync, drift detection, PR-driven deploys)
- Incremental adoption — learn ArgoCD on low-risk workloads first
- ArgoCD itself is simpler when not managing complex StatefulSets
- Clear operational boundary: "if it has PVCs with critical data, use Helm directly"

**Cons:**
- Two deployment methods to maintain
- Team needs to know which workloads use which method
- ArgoCD deployment visibility doesn't include stateful infra

## Trade-off Analysis

The core trade-off is **operational safety vs. deployment automation**.

ArgoCD's fundamental design choice — using `helm template` instead of `helm install` — means it cannot distinguish between a first-time install and an upgrade. For stateless apps, this is irrelevant (they're idempotent by nature). For stateful workloads like Wazuh, this breaks critical assumptions:

1. **Security initialization**: Wazuh's `securityadmin.sh` creates OpenSearch security indices and bcrypt hashes. Running it on every sync could corrupt security state or cause unnecessary cluster disruption.

2. **Data persistence**: OpenSearch StatefulSets with 3 replicas and PVCs contain months of security logs. ArgoCD's auto-prune + PVC sync behavior introduces risk that doesn't exist with `helm upgrade`.

3. **Startup ordering**: Wazuh uses init container chains (Indexer → Manager → Dashboard). These are idempotent (TCP checks), but ArgoCD's sync waves add complexity without benefit over the current working model.

4. **Rollback**: With standalone Helm, `helm rollback` is a single command that restores the previous release. With ArgoCD, rollback requires a Git revert, PR, merge, and sync cycle — slower and more error-prone during an incident.

### Risk matrix

| Scenario | Standalone Helm | ArgoCD |
|---|---|---|
| Accidental PVC deletion | Low (explicit `helm uninstall` blocked by policy) | Medium (auto-prune misconfiguration) |
| Security init re-execution | None (runs only on install) | High (every sync) |
| Rollback during incident | Fast (`helm rollback`) | Slow (Git revert → PR → sync) |
| Drift from desired state | Possible (no detection) | Auto-detected |
| Multi-cluster consistency | Manual | Automated |

For the current team size (1 platform engineer) and risk profile (production SIEM with compliance data), the safety of standalone Helm outweighs the automation benefits of ArgoCD for stateful workloads.

## Consequences

### What becomes easier
- Stateless app deployments get GitOps benefits (auto-sync, PR reviews, drift detection)
- Clear mental model: stateful = Helm, stateless = ArgoCD
- Gradual team learning curve for ArgoCD

### What becomes harder
- No centralized view of ALL deployments (stateful infra requires `helm list` per cluster)
- Multi-cluster stateful deployments remain manual
- Two sets of documentation and runbooks

### What we'll need to revisit
- If team grows beyond 1-2 platform engineers, ArgoCD for stateful may become viable with dedicated SRE oversight
- If Wazuh chart is redesigned to be fully idempotent (no `securityadmin.sh` hook sensitivity), ArgoCD becomes safer
- When ArgoCD adds native `helm install/upgrade` support (tracked in GitHub issues), reassess
- Evaluate Flux CD as alternative — it uses `helm install/upgrade` natively

## Technical Reference

### How ArgoCD handles Helm (critical details)

| Aspect | Standalone Helm | ArgoCD + Helm |
|---|---|---|
| Internal mechanism | `helm install/upgrade` | `helm template` + `kubectl apply` |
| Release tracking | `helm list` shows releases | Nothing in `helm list` |
| Install vs Upgrade | Distinguished (`.Release.IsUpgrade`) | Always false — every op is "sync" |
| Hooks | `pre-install` runs once, `pre-upgrade` on upgrades | Both run on EVERY sync |
| `lookup()` function | Works (API server access) | Returns empty (local rendering) |
| Rollback | `helm rollback <revision>` | Git revert + sync |
| PVC management | Predictable, manual | OutOfSync warnings, silent resize failures |
| Values override | `-f values.yaml` | valueFiles, valuesObject, parameters (precedence chain) |
| CRD updates | `crds/` dir → install once | Same, unless moved to `templates/` |
| Dependencies | `helm dependency build` | Auto-runs, all repos must be registered |

### ArgoCD gotchas for stateful workloads

1. **Hooks**: `pre-install` and `pre-upgrade` hooks execute simultaneously on every sync. Must be perfectly idempotent.
2. **StatefulSet PVCs**: Marked as OutOfSync because `volumeClaimTemplates` generate PVCs at runtime that don't exist in Git.
3. **PVC resize**: Changing `storage` in `volumeClaimTemplates` updates the manifest but does NOT resize existing PVCs. Silent failure.
4. **Auto-prune risk**: If enabled, ArgoCD may delete PVCs it considers orphaned.
5. **Secret rendering**: Secrets rendered by `helm template` pass through ArgoCD's Redis cache in plaintext.
6. **CRD ownership**: Adopting unmanaged CRDs requires manual label patching (`app.kubernetes.io/managed-by=Helm`).

### When to reconsider this decision

- ArgoCD adds native Helm release lifecycle support
- Team grows to 3+ platform engineers with dedicated SRE
- Wazuh chart refactored to be 100% idempotent (no security init sensitivity)
- Flux CD evaluation shows better fit for stateful Helm workloads

## Action Items

1. [x] Research and document ArgoCD + Helm behavioral differences
2. [ ] Evaluate ArgoCD for Alebrije stateless microservices (separate ADR)
3. [ ] Document runbook for multi-cluster Helm deployments without ArgoCD
4. [ ] Evaluate Flux CD as alternative GitOps tool for Helm-native lifecycle
5. [ ] Add this ADR to Confluence knowledge base

## Sources

- [ArgoCD Helm Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)
- [GitHub Issue #1672: helm CLI vs ArgoCD releases](https://github.com/argoproj/argo-cd/issues/1672)
- [GitHub Issue #17604: Helm hooks wrong behavior](https://github.com/argoproj/argo-cd/issues/17604)
- [GitHub Issue #7438: .Release.IsUpgrade alternatives](https://github.com/argoproj/argo-cd/issues/7438)
- [GitHub Issue #4242: StatefulSet PVC always OutOfSync](https://github.com/argoproj/argo-cd/issues/4242)
- [Red Hat: 3 patterns for deploying Helm charts with ArgoCD](https://developers.redhat.com/articles/2023/05/25/3-patterns-deploying-helm-charts-argocd)
