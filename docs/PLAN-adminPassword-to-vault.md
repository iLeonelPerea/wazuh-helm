# Plan: Migrar adminPassword y bootstrapToken a Vault

> **Status:** Pendiente — solo plan, no ejecutar aún
> **Target release:** v1.2.1
> **Tipo de cambio:** `helm upgrade` compatible, backward compatible

---

## Problemas detectados

### 1. adminPassword en texto plano
`security.adminPassword` está en el values file. Es la llave maestra de la que se derivan las 4 credenciales (SHA-256).

### 2. bootstrapToken es obligatorio en cada upgrade
El bootstrap job tiene hooks `pre-install,pre-upgrade` — corre en **cada** `helm upgrade`, no solo la primera vez. Y `bootstrapToken` tiene `required` en el template, así que cualquier upgrade sin token falla. Después del primer install, el bootstrap ya hizo su trabajo (Vault KV seeded, K8s auth configurado, policy creada). Re-ejecutarlo es redundante y peligroso (requiere un token con permisos altos que no debería existir permanentemente).

---

## Solución: Añadir `vault.bootstrap.enabled` flag

Un solo flag que controla si el bootstrap job se ejecuta o no. Después del primer install exitoso, se pone en `false` y nunca más se necesita ni `bootstrapToken` ni `adminPassword` en los values.

---

## Fase 1: Operaciones manuales en Vault (una sola vez, antes del upgrade)

```bash
# Desde vault-0
kubectl exec -it vault-0 -n vault -- sh

# Almacenar adminPassword en Vault para que ESO pueda leerlo
# (el bootstrap job ya lo hizo la primera vez, esto es por si se necesita re-derivar)
vault kv put wazuh/admin-password value="KmtInternal#2026!"

# Verificar que las 4 credenciales existen
vault kv get wazuh/indexer-credentials
vault kv get wazuh/api-credentials
vault kv get wazuh/dashboard-credentials
vault kv get wazuh/filebeat-credentials
```

No se requiere cambio de política — `wazuh-eso-read` ya permite leer `wazuh/data/*`.

---

## Fase 2: Cambios en el chart

### 2.1 values.yaml — Nuevos flags

```yaml
vault:
  enabled: true
  # ... campos existentes (address, authPath, role, mount, tlsSkipVerify) ...

  bootstrap:
    # -- Enable the bootstrap job (seeds Vault KV, configures K8s auth)
    # Set to false after first successful install — bootstrap is one-time
    enabled: true

    # -- Vault token with permissions to seed KV and configure auth
    # Only required when bootstrap.enabled=true
    # Generate with: vault token create -policy=wazuh-bootstrap -ttl=24h
    bootstrapToken: ""

  # -- Read adminPassword from Vault KV instead of Helm values
  # When true: bootstrap job reads from wazuh/admin-password in Vault
  # When false: uses security.adminPassword from values (legacy)
  # Only relevant when bootstrap.enabled=true
  readAdminPasswordFromVault: false

security:
  # -- Admin password for Wazuh Dashboard login
  # After first install with Vault: store in Vault and set vault.readAdminPasswordFromVault=true
  # Then this field can be removed from your values file
  adminPassword: "SecurePassword123!"
```

### 2.2 bootstrap-job.yaml — Condicional completo

Envolver TODO el Job en el flag:

```yaml
{{- if and .Values.vault.enabled .Values.vault.bootstrap.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "wazuh.fullname" . }}-vault-bootstrap
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  # ... todo el Job spec ...
  containers:
    - name: bootstrap
      command:
        - /bin/sh
        - -c
        - |
          {{- if .Values.vault.readAdminPasswordFromVault }}
          # Leer adminPassword de Vault KV
          echo "Reading admin password from Vault..."
          RESPONSE=$(vault_api GET "wazuh/data/admin-password")
          ADMIN_PASSWORD=$(echo "$RESPONSE" | grep -o '"value":"[^"]*"' | cut -d'"' -f4)
          if [ -z "$ADMIN_PASSWORD" ]; then
            echo "ERROR: Could not read admin password from Vault"
            exit 1
          fi
          {{- else }}
          # Leer adminPassword del Secret montado (desde Helm values)
          ADMIN_PASSWORD=$(cat /var/run/secrets/wazuh/password)
          {{- end }}
          # ... resto del script (derivar SHA-256, seed KV, config K8s auth) ...
{{- end }}
```

### 2.3 bootstrap-secrets.yaml — Condicional completo

```yaml
{{- if and .Values.vault.enabled .Values.vault.bootstrap.enabled }}
---
# Bootstrap token Secret
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "wazuh.fullname" . }}-vault-bootstrap-token
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
type: Opaque
stringData:
  token: {{ required "vault.bootstrap.bootstrapToken is required when vault.bootstrap.enabled=true" .Values.vault.bootstrap.bootstrapToken | quote }}
---
{{- if not .Values.vault.readAdminPasswordFromVault }}
# Admin password Secret (solo si NO se lee de Vault)
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "wazuh.fullname" . }}-vault-bootstrap-password
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-10"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
type: Opaque
stringData:
  adminPassword: {{ required "security.adminPassword is required when vault.readAdminPasswordFromVault=false" .Values.security.adminPassword | quote }}
{{- end }}
{{- end }}
```

### 2.4 bootstrap-rbac.yaml — Condicional completo

```yaml
{{- if and .Values.vault.enabled .Values.vault.bootstrap.enabled }}
# ... ServiceAccount, Role, RoleBinding ...
{{- end }}
```

### 2.5 Mover bootstrapToken a la nueva ruta

Actualizar todas las referencias de `.Values.vault.bootstrapToken` a `.Values.vault.bootstrap.bootstrapToken`.

### 2.6 Chart.yaml — Bump version

```yaml
version: 1.2.1
```

---

## Fase 3: Ciclo de vida completo

### Escenario A: Primer install (nuevo cluster)

```bash
# 1. Generar bootstrap token en Vault (24h TTL)
vault token create -policy=wazuh-bootstrap -ttl=24h

# 2. Install con bootstrap habilitado
helm install wazuh wazuh-helm/wazuh -n wazuh \
  -f wazuh.yaml \
  --set vault.bootstrap.enabled=true \
  --set vault.bootstrap.bootstrapToken="hvs.xxx" \
  --set security.adminPassword="MiPassword!"

# 3. Verificar bootstrap exitoso
kubectl logs job/wazuh-vault-bootstrap -n wazuh

# 4. Revocar bootstrap token
vault token revoke hvs.xxx

# 5. Actualizar wazuh.yaml para futuros upgrades:
#    vault.bootstrap.enabled: false
#    (remover bootstrapToken y adminPassword)
```

### Escenario B: Upgrade normal (post-bootstrap)

```bash
# bootstrap.enabled=false → NO corre Job, NO necesita token ni password
helm upgrade wazuh wazuh-helm/wazuh -n wazuh \
  -f wazuh.yaml
# Donde wazuh.yaml tiene:
#   vault.enabled: true
#   vault.bootstrap.enabled: false
#   (sin bootstrapToken ni adminPassword)
```

### Escenario C: Re-bootstrap (rotación de credenciales)

```bash
# 1. Generar nuevo bootstrap token temporal
vault token create -policy=wazuh-bootstrap -ttl=1h

# 2. Upgrade con bootstrap habilitado temporalmente
helm upgrade wazuh wazuh-helm/wazuh -n wazuh \
  -f wazuh.yaml \
  --set vault.bootstrap.enabled=true \
  --set vault.bootstrap.bootstrapToken="hvs.nuevo" \
  --set vault.readAdminPasswordFromVault=true
# Lee el adminPassword de Vault, re-deriva y actualiza las 4 credenciales

# 3. Revocar token y volver a deshabilitar bootstrap
vault token revoke hvs.nuevo
```

---

## Fase 4: Testing

| # | Escenario | bootstrap.enabled | bootstrapToken | adminPassword | readFromVault | Resultado |
|---|---|---|---|---|---|---|
| 1 | Sin Vault (docker-desktop) | N/A | N/A | Sí | N/A | Funciona como antes |
| 2 | Primer install con Vault | true | Sí | Sí | false | Bootstrap seeds Vault |
| 3 | Upgrade normal post-install | false | No | No | N/A | Job NO corre, upgrade limpio |
| 4 | Re-bootstrap con rotación | true | Sí | No | true | Lee de Vault, re-deriva |
| 5 | Upgrade sin token (bootstrap=true) | true | No | - | - | FALLA con error claro |
| 6 | Rollback | false | No | No | N/A | helm rollback funciona |

### Tests a ejecutar:
1. `helm template` con cada combinación de flags (validar render)
2. `helm template` con `bootstrap.enabled=false` → verificar que NO genera Job, Secret, SA, Role, RoleBinding
3. `helm template` con `bootstrap.enabled=true` + token vacío → error `required`
4. Deploy en docker-desktop sin Vault (backward compat)
5. Deploy en docker-desktop con Vault
6. Upgrade en dev cluster con `bootstrap.enabled=false`
7. Verificar que las 4 credenciales derivadas son idénticas (hash determinístico)
8. Verificar dashboard login post-upgrade

---

## Fase 5: Seguridad

- `adminPassword` NUNCA aparece en ConfigMaps, logs, o env vars visibles
- `bootstrapToken` solo existe durante el Job y se auto-limpia (`hook-delete-policy`)
- Después del primer install, ningún token de alto privilegio persiste
- Volume mount del Secret solo existe cuando `bootstrap.enabled=true`
- Vault audit log registra quién lee `wazuh/admin-password`
- En producción: `vault.tlsSkipVerify: false`
- El `required` en el template da error claro si falta el token cuando bootstrap está habilitado

---

## Fase 6: Rollback

Si algo falla:

```bash
# Opción 1: Deshabilitar bootstrap y hacer upgrade normal
helm upgrade wazuh wazuh-helm/wazuh -n wazuh \
  -f wazuh.yaml \
  --set vault.bootstrap.enabled=false

# Opción 2: Rollback completo a revisión anterior
helm rollback wazuh -n wazuh
```

---

## Checklist

```
[ ] Almacenar adminPassword en Vault KV (wazuh/admin-password)
[ ] Modificar values.yaml:
    [ ] Añadir vault.bootstrap.enabled (default: true)
    [ ] Mover bootstrapToken a vault.bootstrap.bootstrapToken
    [ ] Añadir vault.readAdminPasswordFromVault (default: false)
    [ ] Actualizar comentarios/docs
[ ] Modificar bootstrap-job.yaml:
    [ ] Envolver en {{- if and .Values.vault.enabled .Values.vault.bootstrap.enabled }}
    [ ] Añadir lógica dual de lectura de password
[ ] Modificar bootstrap-secrets.yaml:
    [ ] Envolver en condicional de bootstrap.enabled
    [ ] Password Secret condicional en readAdminPasswordFromVault
    [ ] Actualizar ruta de bootstrapToken
[ ] Modificar bootstrap-rbac.yaml:
    [ ] Envolver en condicional de bootstrap.enabled
[ ] Bump Chart.yaml a 1.2.1
[ ] Test: helm template con bootstrap=false (no genera recursos de bootstrap)
[ ] Test: helm template con bootstrap=true + token vacío (error required)
[ ] Test: docker-desktop sin Vault
[ ] Test: docker-desktop con Vault
[ ] Test: upgrade en dev cluster con bootstrap=false
[ ] Test: rollback
[ ] Publicar en ArtifactHub
```

---

## Archivos a modificar

| Archivo | Cambio |
|---|---|
| `values.yaml` | Nuevo `vault.bootstrap.enabled`, mover `bootstrapToken`, añadir `readAdminPasswordFromVault` |
| `Chart.yaml` | Bump a 1.2.1 |
| `templates/vault/bootstrap-job.yaml` | Condicional `bootstrap.enabled` + lógica dual de password |
| `templates/vault/bootstrap-secrets.yaml` | Condicional `bootstrap.enabled` + password condicional |
| `templates/vault/bootstrap-rbac.yaml` | Condicional `bootstrap.enabled` |

---

## Diagrama de flujo

```
helm install/upgrade
  │
  ├─ vault.enabled=false → Deploy sin Vault (legacy, secrets en values)
  │
  └─ vault.enabled=true
       │
       ├─ bootstrap.enabled=false → NO corre Job
       │    └─ ESO ya tiene las credenciales de Vault → pods arrancan normal
       │
       └─ bootstrap.enabled=true → Corre bootstrap Job
            │
            ├─ readAdminPasswordFromVault=false
            │    └─ Lee adminPassword de Helm values → deriva → seed Vault
            │
            └─ readAdminPasswordFromVault=true
                 └─ Lee adminPassword de Vault KV → deriva → re-seed Vault
```
