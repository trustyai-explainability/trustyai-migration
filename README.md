# trustyai-private

If you want, you can backup and restore TrustyAI scheduled metrics during operator upgrades (see [Backup and restore metrics](#backup-and-restore-metrics) at the end).

---

## Fixes

Prereqs: `oc` (and `oc login`). `jq` is optional (it just makes JSON output easier to read).

### Fix 1: GuardrailsOrchestrator (RHOAI 2.25 -> 3.x)

This fix is relevant if you have GuardrailsOrchestrator instances and:

- your GuardrailsOrchestrator `/health` or `/info` endpoints return errors, or
- you enabled OpenTelemetry on RHOAI 2.25 and now the `spec.otelExporter` fields are not compatible with RHOAI 3.x.

#### Step 0: Check if you have GuardrailsOrchestrator instances

```bash
oc get guardrailsorchestrator -n <namespace>
```

If you don't know the namespace, list them across all namespaces:

```bash
oc get guardrailsorchestrator -A
```

If this returns `No resources found`, you can skip Fix 1.

#### Step 1: Fix `/health` and `/info` endpoint errors (deployment readiness probe)

This patches the GuardrailsOrchestrator Deployment(s) to add the expected readiness probe on port `8034` at `/health`.

```bash
./patch-guardrails-deployment.sh <namespace>
```

Verify:

```bash
ORCH_ROUTE_HEALTH=$(oc get routes -n <namespace> guardrails-orchestrator-health -o jsonpath='{.spec.host}')
curl -s https://$ORCH_ROUTE_HEALTH/info | jq
```

If the route name differs, list routes in the namespace and pick the GuardrailsOrchestrator health route:

```bash
oc get routes -n <namespace>
```

#### Step 2: Fix OpenTelemetry `spec.otelExporter` incompatibility (CR migration)

If you enabled OpenTelemetry on RHOAI 2.25, the `spec.otelExporter` keys changed in RHOAI 3.x. This script migrates the old fields to the new ones.

1. Check what would be migrated:

```bash
./migrate-gorch-otel-exporter.sh --namespace <namespace>
./migrate-gorch-otel-exporter.sh --namespace <namespace> --dry-run
```

2. Apply the migration:

```bash
./migrate-gorch-otel-exporter.sh --namespace <namespace> --fix
```

3. Verify the migrated fields (you should see keys like `otlpProtocol`, `otlpTracesEndpoint`, `otlpMetricsEndpoint`, `enableTraces`, `enableMetrics`):

```bash
oc get guardrailsorchestrator -n <namespace> <name> -o jsonpath='{.spec.otelExporter}{"\n"}'
```

### Fix 2: GPU deadlock

This issue can occur when there is a llm deployment and then trustyai service is created in the same namespace. The LLM deployment would be then stuck in `pending`

#### How to identify

1. Look for an InferenceService predictor that has **both** a Running pod and a Pending pod:

```bash
oc get pods -n <namespace> -l component=predictor
```

Typical symptoms:

- Two pods for the same predictor
- One pod **Running**, one pod **Pending**
- Different container counts (e.g. `2/2` vs `0/3`)

2. Use the helper script to check for deadlocks (recommended):

```bash
./break-gpu-deadlock.sh --namespace <namespace> --check
```

#### Solution

To avoid this deadlock, you can run script `break-gpu-deadlock.sh` which will delete the pending pod and then re-create it. This will allow the LLM deployment to proceed without being stuck in pending state. 

1. Fix deadlocks:

```bash
./break-gpu-deadlock.sh --namespace <namespace> --fix
```

2. Verify pods are no longer stuck:

```bash
oc get pods -n <namespace> -l component=predictor
```

---

## Backup and restore metrics

Scripts for backing up and restoring TrustyAI scheduled metrics during operator upgrades on OpenShift.

### Overview

When upgrading the TrustyAI operator, scheduled metric computations (fairness, drift, etc.) need to be backed up and restored. These scripts use the TrustyAI REST API to export and re-import metric configurations.

### Prerequisites

- `oc` CLI tool (OpenShift CLI)
- `jq` (JSON processor)
- `curl` (HTTP client)
- Active OpenShift login session (`oc login`)

### Scripts

- `backup-metrics.sh` - Export all scheduled metrics to JSON
- `restore-metrics.sh` - Re-schedule metrics from backup file

### Upgrade steps

#### Pre-upgrade steps

```bash
NAMESPACE="trustyai-ns"

# 1. Backup before upgrade
./backup-metrics.sh -n ${NAMESPACE}

# 2. Migrate RHOAI
```

##### Backup metrics

```bash
# Basic backup
./backup-metrics.sh -n <namespace>

# Custom backup directory
./backup-metrics.sh -n <namespace> -d /path/to/backups

# Backup only fairness metrics (SPD, DIR)
./backup-metrics.sh -n <namespace> -t fairness
```

#### Post-upgrade steps

```bash
NAMESPACE="trustyai-ns"

# 3. Restore metrics
./restore-metrics.sh -n ${NAMESPACE} -f backups/trustyai-metrics-latest.json
```

##### Restore metrics

```bash
# Basic restore
./restore-metrics.sh -n <namespace> -f backups/trustyai-metrics-YYYYMMDD-HHMMSS.json

# Dry run (preview without making changes)
./restore-metrics.sh -n <namespace> -f backup.json --dry-run

# Skip metrics that already exist
./restore-metrics.sh -n <namespace> -f backup.json --skip-existing
```

**Important:** Restored metrics receive new UUIDs (original IDs are not preserved).

### Backup

**Output files:**
- `trustyai-metrics-YYYYMMDD-HHMMSS.json` - Backup file
- `trustyai-metrics-YYYYMMDD-HHMMSS.metadata.json` - Metadata
- `trustyai-metrics-latest.json` - Symlink to latest

#### Verify backup

```bash
# Check backup file structure
jq . backups/trustyai-metrics-latest.json

# Count metrics in backup
jq '.requests | length' backups/trustyai-metrics-latest.json

# List metrics by type
jq -r '.requests[] | "\(.request.metricName) - \(.request.modelId)"' backups/trustyai-metrics-latest.json
```

#### Backup file format

```json
{
  "requests": [
    {
      "id": "uuid-of-request",
      "request": {
        "modelId": "model-name",
        "metricName": "SPD",
        "protectedAttribute": "attribute-name",
        "privilegedAttribute": {"type": "string", "value": "male"},
        "unprivilegedAttribute": {"type": "string", "value": "female"},
        "outcomeName": "prediction",
        "favorableOutcome": {"type": "int32", "value": 1},
        "batchSize": 5000
      }
    }
  ]
}
```

### Supported Metric Types

**Fairness Metrics:**
- `SPD` - Statistical Parity Difference
- `DIR` - Disparate Impact Ratio

**Drift Metrics:**
- `meanshift` - Mean Shift
- `kstest` - Kolmogorov-Smirnov Test
- `approxkstest` - Approximate KS Test
- `fouriermmd` - Fourier MMD

### Script Options

#### backup-metrics.sh

```
-n, --namespace NAMESPACE    OpenShift namespace (required)
-d, --backup-dir DIR         Backup directory (default: ./backups)
-t, --type TYPE              Filter: all, fairness (default: all)
-l, --route-label LABEL      Route selector (default: app=trustyai-service)
-h, --help                   Show help
```

#### restore-metrics.sh

```
-n, --namespace NAMESPACE    OpenShift namespace (required)
-f, --file FILE              Backup file path (required)
-l, --route-label LABEL      Route selector (default: app=trustyai-service)
-d, --dry-run                Preview without making changes
-s, --skip-existing          Skip metrics that already exist
-h, --help                   Show help
```

### API Endpoints Used

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/metrics/all/requests` | GET | List all scheduled metrics |
| `/metrics/all/requests?type=fairness` | GET | List fairness metrics only |
| `/metrics/group/fairness/spd/request` | POST | Schedule SPD metric |
| `/metrics/group/fairness/dir/request` | POST | Schedule DIR metric |
| `/metrics/drift/meanshift/request` | POST | Schedule meanshift metric |
| `/metrics/drift/kstest/request` | POST | Schedule KS test metric |
| `/metrics/drift/approxkstest/request` | POST | Schedule approx KS test |
| `/metrics/drift/fouriermmd/request` | POST | Schedule Fourier MMD |

All requests require authentication: `-H "Authorization: Bearer $(oc whoami -t)"`

### Troubleshooting

#### Authentication errors

```bash
# Verify login
oc whoami

# Check token
oc whoami -t

# Re-login if needed
oc login <cluster-url>
```

#### Cannot find TrustyAI route

```bash
# List routes
oc get route -n <namespace>

# Check TrustyAI deployment
oc get deployment -n <namespace> -l app=trustyai-service
```

#### Restore fails with HTTP errors

```bash
# Check service health
oc get pods -n <namespace> -l app=trustyai-service

# View logs
oc logs -n <namespace> -l app=trustyai-service --tail=50

# Verify backup file
jq empty backup.json && echo "Valid JSON" || echo "Invalid JSON"
```

#### Metrics not appearing after restore

Wait a few seconds and verify:

```bash
AUTH_TOKEN=$(oc whoami -t)
ROUTE=$(oc get route -n <namespace> -l app=trustyai-service -o jsonpath='{.items[0].spec.host}')

# List current metrics
curl -s "https://${ROUTE}/metrics/all/requests" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" | jq '.requests | length'

# Check service info
curl -s "https://${ROUTE}/info" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" | jq '.'
```
