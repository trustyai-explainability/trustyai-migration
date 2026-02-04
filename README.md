# trustyai-private

## GPU deadlock

This issue can occur when there is a llm deployment and then trustyai service is created in the same namespace. The LLM deployment would be then stuck in `pending`

## Steps to recreate

1. Create a namespace

```bash
oc new-project gpu-deadlock
```

2. Deploy LLM

```bash
oc apply -f recreate-manifests/deploy-llm.yaml -n gpu-deadlock
```

3. Deploy TAS

```bash
oc apply -f recreate-manifests/deploy-tas.yaml -n gpu-deadlock
``` 

4. Display pods

```bash
oc get pods -n gpu-deadlock
```

this should return

```
`llm-minio-container-7f4db4c484-sj86h   1/1     Running   0          2m6s
llm-predictor-765c89b8b9-8lstm         2/2     Running   0          2m5s
llm-predictor-fb6f8f687-5478c          0/3     Pending   0          105s
trustyai-service-6db776464c-jv6r8      2/2     Running   0          105s
```

Not the pending pod

## Solution

To avoid this deadlock, you can run script `break-gpu-deadlock.sh` which will delete the pending pod and then re-create it. This will allow the LLM deployment to proceed without being stuck in pending state. 

1. To get help on the script

```bash
./break-gpu-deadlock.sh --help
```

this should return

```
Usage: ./break-gpu-deadlock.sh --namespace <namespace> [--check|--fix]

Options:
  -n, --namespace <name>  Namespace to scan
  --check                 Check for deadlocks (default)
  --fix                   Fix detected deadlocks
```

2. To check for deadlocks

```bash
./break-gpu-deadlock.sh --namespace gpu-deadlock --check
```

this should return

```
DEADLOCK: llm
  Running: llm-predictor-765c89b8b9-8lstm
  Pending: llm-predictor-fb6f8f687-5478c

To fix: ./break-gpu-deadlock.sh --namespace gpu-deadlock --fix
```

3. To fix deadlocks

```bash
./break-gpu-deadlock.sh --namespace gpu-deadlock --fix
```

this should return

```
DEADLOCK: llm
  Running: llm-predictor-765c89b8b9-8lstm
  Pending: llm-predictor-fb6f8f687-5478c

pod "llm-predictor-765c89b8b9-8lstm" deleted
pod/llm-predictor-fb6f8f687-5478c condition met
✓ Fixed
```

4. Check pods again

```bash
oc get pods -n gpu-deadlock
```

this should return

```
llm-minio-container-7f4db4c484-sj86h   1/1     Running   0          5m35s
llm-predictor-fb6f8f687-5478c          3/3     Running   0          5m14s
trustyai-service-6db776464c-jv6r8      2/2     Running   0          5m14s
```