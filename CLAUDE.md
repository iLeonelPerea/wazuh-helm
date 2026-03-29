# Wazuh Helm Chart - Project Context

## Repository
- **Source:** `~/Documents/cowork/work/kamet/infra/wazuh-helm`
- **GitHub:** https://github.com/iLeonelPerea/wazuh-helm
- **ArtifactHub:** https://artifacthub.io/packages/helm/wazuh-helm-eks/wazuh
- **Current Version:** 1.0.1

## Clusters
- **Dev:** EKS Auto Mode `kamet-dev` (account 058264491838, us-east-1, profile `kamet-dev`)
- **Prod:** EKS Auto Mode `kamet-prod` (account 533267243705, us-east-1, profile `kamet-prod`) — Pending deployment

## Namespace
`wazuh`

## Credentials
- **Dashboard login:** admin / SecurePassword123! (configurable via `security.adminPassword`)
- **Internal passwords:** Derived automatically from adminPassword via SHA-256 (kibanaserver, filebeat, API)
- **No manual hashes needed** — security init container generates bcrypt hashes at startup

## Architecture
- 3x Indexer (OpenSearch cluster with quorum, parallel bootstrap)
- 2x Manager (master + worker cluster mode)
- 1x Dashboard
- Nx Agents (DaemonSet on all general-purpose nodes)
- S3 sidecar for cold storage
- Cert rotation CronJob
- Cleanup CronJob for vd_updater temp files

## Node Isolation
- **Wazuh NodePool:** Karpenter NodePool `wazuh` with taint `workload=wazuh:NoSchedule`
- **General-purpose NodePool:** No taint, agents run here
- Indexer, managers, dashboard have `nodeSelector: workload=wazuh` + matching toleration
- Agents do NOT have nodeSelector — run on all nodes

## Startup Order (Validated 2026-03-29)
Init containers enforce dependency chain — no component starts until its dependencies are ready:
```
Indexer (free start)
  ↓ wait-for-indexer (TCP 9200)
Manager
  ↓ wait-for-dependencies (TCP 9200 + TCP 55000)
Dashboard
Agents (DaemonSet — NO init container wait, uses native retry)
```
- Wait containers use busybox `nc -zw2` with 120 attempts × 5s = 10min timeout
- Manager readiness probe: initialDelaySeconds=45 (allows postStart hook to complete)
- Agents use Wazuh's built-in resilience (retry every 10-30s, auto-register when manager ready)
- Do NOT add wait-for-manager to agents — it would block ALL agents on ALL nodes during manager downtime

## Values Files
- `values.yaml` — Chart defaults
- `values-dev.yaml` — Dev cluster overrides (DO NOT commit, in .gitignore)

## Install Command
```bash
helm install wazuh . -n wazuh --create-namespace -f values-dev.yaml
```

## Upgrade Command (ALWAYS use upgrade, NEVER uninstall+install)
```bash
helm upgrade wazuh . -n wazuh -f values-dev.yaml
```

## Critical Rules
1. **NEVER do helm uninstall IN PRODUCTION (EKS)** — causes Karpenter to consolidate all nodes, cascade DNS failures. In local (docker-desktop) environments, helm uninstall is safe.
2. **Always use helm upgrade in production** — even for "fresh" deploys, delete PVCs individually if needed. In local dev, full uninstall+reinstall cycles are acceptable for testing.
3. **NEVER delete pods outside wazuh namespace** without explicit user authorization
4. **consolidateAfter: 10m** on both NodePools to avoid aggressive recycling
5. **EKS Auto Mode DNS:** CoreDNS runs as systemd, can break after node recycle. Use FQDN + env vars to minimize DNS dependency
6. **Docker Hub rate limit:** Use ECR images for auxiliary containers (`public.ecr.aws/docker/library/busybox:1.36`)
7. **OpenSearch security:** Init container generates hashes + runs securityadmin.sh. Never run securityadmin.sh manually unless emergency

## Security Hardening (Validated 2026-03-29)
- **seccompProfile: RuntimeDefault** on all pods
- **capabilities drop: ALL** on every container, with minimal adds per component
- **allowPrivilegeEscalation: false** on all containers
- **Dashboard:** runAsNonRoot: true, runAsUser: 1000, no extra capabilities
- **Indexer:** runAsNonRoot: true, runAsUser: 1000, volume-permissions init uses CHOWN only
- **Manager:** runAsUser: 0 (required), capabilities: CHOWN, DAC_OVERRIDE, FOWNER, KILL, NET_BIND_SERVICE, NET_RAW, SETGID, SETUID, SYS_CHROOT
- **wazuh.yml:** Created by init container (UID 65534) with chmod 640 — fsGroup 1000 ensures dashboard can read but NOT write (prevents duplicate `hosts:` key crash)
- **NetworkPolicies:** Defined in `templates/network-policies.yaml`, toggled via `networkPolicy.enabled`
- **Vault bridge init containers:** runAsUser: 65534 (nobody), no escalation
- **All init containers:** runAsNonRoot: true, capabilities drop ALL

## Data Flow
```
Container logs → Agent (DaemonSet) → Manager (analysisd) → Filebeat → Indexer (OpenSearch)
                                                              ↓
                                                        S3 sidecar → S3 bucket
```

## Retention
- Dashboard (OpenSearch): 180 days (ISM policy)
- S3 Standard: 6 months
- S3 Glacier: Indefinite (pending Lifecycle config)

## AWS Infrastructure (to import to Terragrunt)
- S3 Bucket: `wazuh-archives-058264491838`
- IAM Role: `kamet-dev-wazuh-archives` (Pod Identity)
- IAM Policy: `kamet-dev-wazuh-archives-s3`
- Pod Identity Association: `a-hocy5ic9y62l9tsz0`

## Pending Work

### High Priority
- Deploy to prod cluster (kamet-prod, account 533267243705)
- Import AWS resources to Terragrunt
- S3 Lifecycle → Glacier after 6 months
- Confluence doc — Knowledge base CoreDNS/OOM

### Medium Priority
- Cert rotation testing (CronJob created, needs validation)
- Custom detection rules for kamet APIs (auth failures, rate limiting, 5xx)
- Log rotation validation (local_internal_options.conf)
- NetworkPolicy for multi-cluster ingestion via Transit Gateway

### Improvements Backlog
- allow_unsafe_democertificates: true → proper cert validation
- S3 sync error handling for expired credentials
- Agent DNS nslookup parsing hardening
- Cert expiration monitoring (12 → 5 years, with rotation)
- Prometheus opensearch-exporter sidecar
- Dashboard SSL for production (behind Ingress/Traefik)
- Agent privileged + hostPID documentation
- OpenClaw/AI agent integration for automated incident response

### Jira Epic: Platform Engineering Initiatives - Q2 2026
1. Configure HPA for Java workloads with JVM-aware scaling
2. Deploy Wazuh SIEM to production cluster with multi-account ingestion
3. Build infrastructure test suite (Helm validation, smoke tests, integration)
4. Gather infrastructure requirements from engineering leads
5. Deploy AI agent platform for operational automation (OpenClaw POC)
6. Resolve critical infrastructure issues (DNS, node stability, EKS Auto Mode)
7. Design and execute Disaster Recovery Plan testing
8. Evaluate Crossplane for infrastructure-as-code (vs Terragrunt)
9. Centralize Helm charts in dedicated repository with CI/CD
