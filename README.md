# trustyai-private

## Metrics Migration

Scripts for backing up and restoring TrustyAI scheduled metrics during operator upgrades on OpenShift.

### Overview

When upgrading the TrustyAI operator, scheduled metric computations (fairness, drift, etc.) need to be backed up and restored. These scripts use the TrustyAI REST API to export and re-import metric configurations.

### Scripts

- `backup-metrics.sh` - Export all scheduled metrics to JSON
- `restore-metrics.sh` - Re-schedule metrics from backup file

### Prerequisites

- `oc` CLI tool (OpenShift CLI)
- `jq` (JSON processor)
- `curl` (HTTP client)
- Active OpenShift login session (`oc login`)

### Quick Start

#### Backup metrics

```bash
# Basic backup
./backup-metrics.sh -n <namespace>

# Custom backup directory
./backup-metrics.sh -n <namespace> -d /path/to/backups

# Backup only fairness metrics (SPD, DIR)
./backup-metrics.sh -n <namespace> -t fairness
```

#### Restore metrics

```bash
# Basic restore
./restore-metrics.sh -n <namespace> -f backups/trustyai-metrics-YYYYMMDD-HHMMSS.json

# Dry run (preview without making changes)
./restore-metrics.sh -n <namespace> -f backup.json --dry-run

# Skip metrics that already exist
./restore-metrics.sh -n <namespace> -f backup.json --skip-existing
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

### Usage Examples

#### Complete upgrade workflow

```bash
NAMESPACE="trustyai-ns"

# 1. Backup before upgrade
./backup-metrics.sh -n ${NAMESPACE}

# 2. Migrate RHOAI

# 3. Restore metrics
./restore-metrics.sh -n ${NAMESPACE} -f backups/trustyai-metrics-latest.json
```

#### Verify backup

```bash
# Check backup file structure
jq . backups/trustyai-metrics-latest.json

# Count metrics in backup
jq '.requests | length' backups/trustyai-metrics-latest.json

# List metrics by type
jq -r '.requests[] | "\(.request.metricName) - \(.request.modelId)"' backups/trustyai-metrics-latest.json
```

### Script Options

#### backup-metrics.sh

```
-n, --namespace NAMESPACE    OpenShift namespace (required)
-d, --backup-dir DIR         Backup directory (default: ./backups)
-t, --type TYPE              Filter: all, fairness (default: all)
-l, --route-label LABEL      Route selector (default: app=trustyai-service)
-h, --help                   Show help
```

**Output files:**
- `trustyai-metrics-YYYYMMDD-HHMMSS.json` - Backup file
- `trustyai-metrics-YYYYMMDD-HHMMSS.metadata.json` - Metadata
- `trustyai-metrics-latest.json` - Symlink to latest

#### restore-metrics.sh

```
-n, --namespace NAMESPACE    OpenShift namespace (required)
-f, --file FILE              Backup file path (required)
-l, --route-label LABEL      Route selector (default: app=trustyai-service)
-d, --dry-run                Preview without making changes
-s, --skip-existing          Skip metrics that already exist
-h, --help                   Show help
```

**Important:** Restored metrics receive new UUIDs (original IDs are not preserved).

### Backup File Format

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

