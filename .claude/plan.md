# Plan: Wazuh Manager Cluster Mode

## Resumen
Agregar soporte de cluster mode al Helm chart para que el Wazuh Manager pueda correr con 1 master + N workers. Incluye también documentar affinity/tolerations/nodeSelector en values.yaml (los templates ya los soportan), rotación de logs, y reglas custom de detección.

## Arquitectura del Cluster

```
                    ┌─────────────────┐
                    │  Agents (1514)  │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  ClusterIP Svc  │ (load balances to all managers)
                    │  wazuh-manager  │
                    │    -agents      │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
    ┌─────────▼──┐  ┌───────▼────┐  ┌──────▼─────┐
    │  manager-0 │  │ manager-1  │  │ manager-2  │
    │  (master)  │◄─┤  (worker)  │  │  (worker)  │
    │            │  │            │  │            │
    └────────────┘  └────────────┘  └────────────┘
         port 1516 ◄─── cluster sync ───►
```

- **Pod ordinal 0** = master (siempre)
- **Pod ordinal 1+** = workers
- Comunicación inter-nodo via **headless service** en puerto 1516 (ya definido)
- Agents se conectan al **ClusterIP service** que balancea a todos los managers
- Cada manager tiene su propio PVC (ya funciona así con StatefulSet)

## Archivos a modificar

### 1. `values.yaml`
Agregar:
```yaml
manager:
  cluster:
    enabled: false          # default off para backward compatibility
    name: "wazuh-cluster"
    key: ""                 # 32-char key, auto-generado si vacío

  # Log rotation (monitord)
  logRetentionDays: 7       # días de logs rotados en disco local

  # Scheduling (ya soportados en templates, solo documentar)
  nodeSelector: {}
  affinity: {}
  tolerations: []

# Lo mismo para indexer, dashboard, agent:
indexer:
  nodeSelector: {}
  affinity: {}
  tolerations: []

dashboard:
  nodeSelector: {}
  affinity: {}
  tolerations: []

agent:
  nodeSelector: {}
  tolerations: []   # nota: el daemonset ya incluye toleration NoSchedule por default
```

### 2. `templates/secrets/cluster-key.yaml` — NUEVO
- Secret con la cluster key
- Si `manager.cluster.key` está vacío, usar `randAlphaNum 32` con `lookup` para no regenerar en cada upgrade
- Solo se crea cuando `manager.cluster.enabled: true`

### 3. `templates/manager/configmap.yaml`
Agregar a `ossec.conf`:
- Bloque `<cluster>` condicional (cuando `.Values.manager.cluster.enabled`)
- El `node_name` y `node_type` usan placeholder `__NODE_NAME__` y `__NODE_TYPE__` que postStart reemplaza
- El master address usa el DNS del headless service: `wazuh-manager-0.wazuh-manager.<namespace>.svc.cluster.local`

Agregar al data:
- `local_internal_options.conf` con settings de monitord para rotación de logs
- `local_rules.xml` con reglas custom de detección para kamet APIs

### 4. `templates/manager/statefulset.yaml`
Modificar postStart para:
- Detectar ordinal del hostname (`${HOSTNAME##*-}`)
- Si cluster enabled: reemplazar `__NODE_TYPE__` con `master` (ordinal 0) o `worker` (ordinal N)
- Si cluster enabled: reemplazar `__NODE_NAME__` con `master-node` o `worker-N`
- Copiar `local_internal_options.conf` y `local_rules.xml` al PVC
- Inyectar cluster key desde env var (montado del Secret)

Agregar env var:
- `CLUSTER_KEY` desde el secret `cluster-key`

### 5. `templates/manager/pdb.yaml`
- Ajustar `minAvailable` cuando cluster está habilitado (al menos 1 master disponible)

## Reglas Custom de Detección (`local_rules.xml`)

Basado en el formato real de logs que vimos (Spring Boot + CRI):
```
2026-03-21T00:49:22.437Z trace_id= span_id= trace_flags= INFO 1 --- [thread] class : message
```

Reglas:
- **100001** (level 12): HTTP 5xx - `statusCode":5` o ` 5\d\d `
- **100002** (level 8): HTTP 401 Unauthorized
- **100003** (level 8): HTTP 403 Forbidden
- **100004** (level 8): HTTP 429 Rate Limit
- **100005** (level 6): Spring Boot ERROR level
- **100006** (level 4): Spring Boot WARN level
- **100010** (level 14): 5+ auth failures en 2 minutos (brute force)
- **100011** (level 14): 10+ server errors en 5 minutos (service degradation)

## Lo que NO cambia
- Dashboard: sigue conectando al service `wazuh-manager` → funciona igual
- Agents: siguen conectando al ClusterIP service → Kubernetes balancea
- Indexer: sin cambios, cada manager tiene su propio Filebeat que envía al indexer
- Certs: sin cambios, los certs actuales funcionan para todos los managers
- S3 sidecar: corre en cada pod manager, cada uno sincroniza sus propios archives

## Orden de implementación
1. Agregar scheduling (affinity/tolerations) a values.yaml — trivial, solo documentar
2. Agregar rotación de logs (local_internal_options.conf)
3. Agregar reglas custom (local_rules.xml)
4. Agregar cluster mode (secret, configmap, statefulset)
5. Validar con `helm template` que renderiza correctamente
