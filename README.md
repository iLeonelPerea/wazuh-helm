# Wazuh Helm Chart

Production-ready [Wazuh](https://wazuh.com/) SIEM deployment for Kubernetes, optimized for **EKS Auto Mode**.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                     │
│                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │   Indexer     │  │   Manager    │  │  Dashboard   │   │
│  │ (OpenSearch)  │  │  + Filebeat  │  │  (UI :5601)  │   │
│  │  :9200/:9300  │  │  :1514/1515  │  │              │   │
│  │  StatefulSet  │  │  StatefulSet │  │  Deployment  │   │
│  │  PVC (gp3)   │  │  PVC (gp3)   │  │              │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────────┘   │
│         │                  │                              │
│         │     ┌────────────┤                              │
│         │     │            │                              │
│  ┌──────┴─────┴──┐  ┌─────┴────────┐                    │
│  │  TLS Certs    │  │ Agent        │                    │
│  │  (pre-install │  │ (DaemonSet)  │                    │
│  │   hook)       │  │ per node     │                    │
│  └───────────────┘  └──────────────┘                    │
│                                                           │
│  Optional:                                                │
│  ┌──────────────┐  ┌──────────────┐                      │
│  │ S3 Sidecar   │  │ Cleanup      │                      │
│  │ (aws-cli)    │  │ CronJob      │                      │
│  │ cold storage │  │ vd_updater   │                      │
│  └──────────────┘  └──────────────┘                      │
└─────────────────────────────────────────────────────────┘
```

## Components

| Component | Type | Description |
|-----------|------|-------------|
| **Indexer** | StatefulSet | Wazuh Indexer (OpenSearch) for alert/archive storage |
| **Manager** | StatefulSet | Wazuh Manager with Filebeat for log processing |
| **Dashboard** | Deployment | Wazuh Dashboard (OpenSearch Dashboards) web UI |
| **Agent** | DaemonSet | Wazuh Agent on every node for log collection |
| **Certs Generator** | Job (pre-install) | Auto-generates TLS certificates on first install |
| **S3 Sync** | Sidecar (optional) | Syncs archives to S3 for cold storage |
| **Cleanup** | CronJob (optional) | Cleans vd_updater temp files (4.14.x bug workaround) |

## Quick Start

### Prerequisites

- Kubernetes 1.28+
- Helm 3.x
- A StorageClass with dynamic provisioning (default: `gp3` with EBS CSI)

### Install

```bash
# Clone the repository
git clone https://github.com/ileonelperea/wazuh-helm.git
cd wazuh-helm

# Install with default values
helm install wazuh . -n wazuh --create-namespace

# Or install with custom values
helm install wazuh . -n wazuh --create-namespace -f my-values.yaml
```

### Minimal custom values

```yaml
# my-values.yaml
global:
  timezone: "America/Mexico_City"

security:
  indexerPassword: "YourSecurePassword123!"
  indexerPasswordHash: "$2a$12$..."  # bcrypt hash of your password
  apiPassword: "YourAPIPassword!"
```

### Access the Dashboard

```bash
# Port-forward the dashboard
kubectl port-forward svc/wazuh-dashboard 5601:5601 -n wazuh

# Open in browser: http://localhost:5601
# Login: admin / <your indexerPassword>
```

## Configuration

### Global

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.timezone` | Timezone for all containers | `"UTC"` |

### Security

| Parameter | Description | Default |
|-----------|-------------|---------|
| `security.indexerUsername` | OpenSearch admin username | `"admin"` |
| `security.indexerPassword` | OpenSearch admin password | `"SecurePassword123!"` |
| `security.indexerPasswordHash` | Bcrypt hash ($2a) of admin password | (default hash) |
| `security.apiUsername` | Wazuh API username | `"wazuh-wui"` |
| `security.apiPassword` | Wazuh API password | `"MyS3cr37P450r.*-"` |
| `security.kibanaserverPassword` | Dashboard internal user password | `"kibanaserver"` |
| `security.kibanaserverPasswordHash` | Bcrypt hash of kibanaserver password | (default hash) |

> **Generate a bcrypt hash:**
> ```bash
> docker run --rm -it wazuh/wazuh-indexer:4.14.4 bash -c \
>   "plugins/opensearch-security/tools/hash.sh -p 'YourPassword'"
> ```

### Indexer

| Parameter | Description | Default |
|-----------|-------------|---------|
| `indexer.replicas` | Number of indexer replicas | `1` |
| `indexer.resources.limits.memory` | Memory limit | `3Gi` |
| `indexer.javaOpts` | JVM heap settings | `"-Xms1g -Xmx1g"` |
| `indexer.storage.size` | PVC size | `10Gi` |

### Manager

| Parameter | Description | Default |
|-----------|-------------|---------|
| `manager.replicas` | Number of manager replicas | `1` |
| `manager.storage.size` | PVC size (30Gi+ recommended) | `30Gi` |
| `manager.feedUpdateInterval` | Vulnerability feed update interval | `"12h"` |
| `manager.logallJson` | Log all events to archives (not just alerts) | `true` |

### Agent

| Parameter | Description | Default |
|-----------|-------------|---------|
| `agent.enabled` | Deploy agent DaemonSet | `true` |
| `agent.monitoredNamespaces` | Namespaces to monitor (empty = all) | `[]` |
| `agent.siemOnly` | Disable infra monitoring (use with Prometheus) | `true` |
| `agent.group` | Agent group for centralized config | `"default"` |

### S3 Archive Sync

| Parameter | Description | Default |
|-----------|-------------|---------|
| `s3.enabled` | Enable S3 archive sidecar | `false` |
| `s3.bucket` | S3 bucket name | `""` |
| `s3.region` | AWS region | `"us-east-1"` |
| `s3.syncIntervalSeconds` | Sync interval in seconds | `300` |

> **Note:** S3 sync requires IAM permissions. On EKS, use [Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) or IRSA to grant the `wazuh-manager` ServiceAccount access to your S3 bucket.

### Cleanup CronJob

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cleanup.enabled` | Enable vd_updater cleanup CronJob | `true` |
| `cleanup.schedule` | Cron schedule | `"0 */2 * * *"` |

### StorageClass

| Parameter | Description | Default |
|-----------|-------------|---------|
| `storageClass.create` | Create StorageClass resource | `true` |
| `storageClass.provisioner` | CSI provisioner | `ebs.csi.eks.amazonaws.com` |
| `storageClass.type` | EBS volume type | `gp3` |

## EKS Auto Mode Notes

This chart is optimized for [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html):

- **StorageClass provisioner**: Uses `ebs.csi.eks.amazonaws.com` (not the legacy `kubernetes.io/aws-ebs`)
- **vm.max_map_count**: Bottlerocket nodes already have `vm.max_map_count=524288` — no init container needed
- **CoreDNS**: Runs as a systemd service on nodes, not as a Kubernetes pod
- **Pod Identity**: Recommended for S3 access (no OIDC provider configuration needed)

## Data Retention

For production deployments, configure an ISM (Index State Management) policy in OpenSearch:

```json
{
  "policy": {
    "description": "Wazuh index retention - 6 months hot, then delete",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [],
        "transitions": [
          {
            "state_name": "delete",
            "conditions": { "min_index_age": "180d" }
          }
        ]
      },
      {
        "name": "delete",
        "actions": [{ "delete": {} }]
      }
    ],
    "ism_template": [
      { "index_patterns": ["wazuh-alerts-*"], "priority": 100 },
      { "index_patterns": ["wazuh-archives-*"], "priority": 100 },
      { "index_patterns": ["wazuh-monitoring-*"], "priority": 100 },
      { "index_patterns": ["wazuh-statistics-*"], "priority": 100 }
    ]
  }
}
```

## Troubleshooting

### Disk filling up on Manager PVC

The vulnerability detector in Wazuh 4.14.x has a known issue where temp files in `/var/ossec/data/queue/vd_updater/tmp/` are never cleaned automatically. Enable the cleanup CronJob (`cleanup.enabled: true`) and consider increasing `manager.feedUpdateInterval` to `12h`.

### Helm install timeout

If the pre-install certificate generation job times out, check that the namespace exists and the service account has permissions to create secrets.

### Agent DNS resolution

Agents use an init container to resolve the manager's ClusterIP before starting. If agents are stuck in init, check that the manager service is running.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
