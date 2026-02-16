#!/usr/bin/env bash
set -euo pipefail

# Pre-upgrade checks for GuardrailsOrchestrator on RHOAI 2.25.

FAILED_ITEMS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if ! command -v oc &>/dev/null; then
  echo -e "${RED}ERROR: oc not found${NC}" >&2
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo -e "${RED}ERROR: Not logged in to cluster (run oc login)${NC}" >&2
  exit 1
fi

echo -e "${BOLD}=== GuardrailsOrchestrator pre-upgrade check ===${NC}"
echo ""

# --- 1. List GuardrailsOrchestrator across all namespaces ---
echo -e "${BOLD}Listing GuardrailsOrchestrator instances (all namespaces)${NC}"
GORCH_LIST=$(oc get guardrailsorchestrator -A --no-headers 2>/dev/null || true)

if [[ -z "${GORCH_LIST}" ]]; then
  echo -e "${YELLOW}No resources found. You can ignore Guardrails-related steps.${NC}"
  exit 0
fi

echo "$GORCH_LIST"
echo ""

# Parse into array of "namespace/name"
GORCH_ITEMS=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  ns=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  GORCH_ITEMS+=("${ns}/${name}")
done <<< "$GORCH_LIST"

BACKUP_DIR="${BACKUP_DIR:-./gorch-otel-backups}"
mkdir -p "$BACKUP_DIR"

ANY_FAILED=0
FAILED_ITEMS=()

for item in "${GORCH_ITEMS[@]}"; do
  NS="${item%%/*}"
  GORCH_NAME="${item##*/}"
  export NS
  STEP1_FAIL=0
  STEP2_FAIL=0
  STEP3_FAIL=0
  STEP4_FAIL=0
  FAILED_THIS_ITERATION=0
  echo -e "${BOLD}----------------------------------------${NC}"
  echo -e "${BOLD}Pre-checks for GuardrailsOrchestrator instance ${CYAN}${GORCH_NAME}${NC} in namespace ${CYAN}${NS}${NC} "
  echo ""

  # Discover GuardrailsOrchestrator ConfigMap
  ORCH_CONFIGMAP=""
  for dep in $(oc get deployment -n "$NS" -o name 2>/dev/null); do
    dep_name="${dep#deployment.apps/}"
    if [[ "$dep_name" == *"guardrails"* ]] || [[ "$dep_name" == *"orchestrator"* ]] || [[ "$dep_name" == "$GORCH_NAME" ]]; then
      ORCH_CONFIGMAP=$(oc get deployment -n "$NS" "$dep_name" -o jsonpath='{range .spec.template.spec.volumes[*]}{.configMap.name}{"\n"}{end}' 2>/dev/null | head -1)
      [[ -n "$ORCH_CONFIGMAP" ]] && break
    fi
  done
  if [[ -z "${ORCH_CONFIGMAP}" ]]; then
    for cm in $(oc get configmap -n "$NS" -o name 2>/dev/null); do
      cm_name="${cm#configmap/}"
      if oc get configmap -n "$NS" "$cm_name" -o jsonpath='{.data.config\.yaml}' &>/dev/null; then
        ORCH_CONFIGMAP="$cm_name"
        break
      fi
    done
  fi

  CONFIGMAP=""
  if [[ -n "${ORCH_CONFIGMAP}" ]]; then
    CONFIGMAP=$(oc get configmap "$ORCH_CONFIGMAP" -n "$NS" -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
  fi

  # --- 1. Validate GuardrailsOrchestrator ConfigMap ---
  echo -e "${BOLD}1. Validating GuardrailsOrchestrator ConfigMap (namespace ${NS})${NC}"

  if [[ -z "${ORCH_CONFIGMAP}" ]]; then
    echo -e "${RED}  FAIL: Could not find orchestrator ConfigMap (with data.config.yaml) in ${NS}.${NC}"
    STEP1_FAIL=1
  else
    echo -e "  ConfigMap: ${CYAN}${ORCH_CONFIGMAP}${NC}"
    if echo "$CONFIGMAP" | grep -q 'chat_generation' && echo "$CONFIGMAP" | grep -q 'detectors:'; then
      echo -e "  ${GREEN}OK: chat_generation and detectors present${NC}"
    else
      echo -e "  ${RED}FAIL: missing chat_generation or detectors${NC}"
      STEP1_FAIL=1
    fi
  fi
  echo ""

  # --- 2. Validate only the inference service listed as chat_generation in the config ---
  echo -e "${BOLD}2. Validating LLM listed in chat_generation (namespace ${NS})${NC}"

  # Parse chat_generation hostname and port from config (ConfigMap config.yaml)
  CHAT_HOSTNAME=""
  CHAT_PORT="8080"
  if [[ -n "$CONFIGMAP" ]] && echo "$CONFIGMAP" | grep -q 'chat_generation'; then

    if [[ -z "${CHAT_HOSTNAME}" ]]; then
      _line=$(echo "$CONFIGMAP" | grep -A 200 'chat_generation' | grep -E '^\s*hostname:' | head -1)
      [[ -z "${_line}" ]] && _line=$(echo "$CONFIGMAP" | grep -E 'hostname:' | head -1)
      if [[ -n "${_line}" ]]; then
        CHAT_HOSTNAME=$(echo "${_line}" | sed 's/.*hostname:[[:space:]]*//' | sed "s/^['\"]//;s/['\"].*//" | tr -d '\r' | head -c 256)
      fi
      _port_line=$(echo "$CONFIGMAP" | grep -A 200 'chat_generation' | grep -E '^\s*port:' | head -1)
      if [[ -n "${_port_line}" ]]; then
        _p=$(echo "${_port_line}" | sed 's/.*port:[[:space:]]*//' | grep -oE '^[0-9]+' || true)
        [[ -n "${_p}" ]] && CHAT_PORT="${_p}"
      fi
    fi
  fi

  if [[ -z "${CHAT_HOSTNAME}" ]]; then
    echo -e "${YELLOW}  FAIL: chat_generation.service.hostname not found in config (or no ConfigMap).${NC}"
    STEP2_FAIL=1
  else
    CHAT_SVC_NAME="${CHAT_HOSTNAME%%.*}"
    echo -e "  chat_generation hostname from config: ${CYAN}${CHAT_HOSTNAME}${NC} (service: ${CHAT_SVC_NAME}, port: ${CHAT_PORT})"

    MODEL_POD=$(oc get endpoints -n "$NS" "$CHAT_SVC_NAME" -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null) || true
    if [[ -z "${MODEL_POD}" ]]; then
      MODEL_POD=$(oc get pods -n "$NS" -l "serving.kserve.io/inferenceservice=${CHAT_SVC_NAME%-predictor},component=predictor" --no-headers -o custom-columns=NAME:.metadata.name --field-selector=status.phase=Running 2>/dev/null | head -1) || true
    fi

    if [[ -z "${MODEL_POD}" ]]; then
      echo -e "${YELLOW}  INFO: No pod found for chat_generation service ${CHAT_SVC_NAME} in ${NS}. Please deploy the InferenceService and try again.${NC}"
      STEP2_FAIL=1
    else
      PORT="${PORT:-${CHAT_PORT}}"
      export PORT
      MODEL_NAME="${MODEL_NAME:-${CHAT_SVC_NAME%-predictor}}"
      [[ -z "$MODEL_NAME" ]] && MODEL_NAME="${CHAT_SVC_NAME}"
      export MODEL_NAME


      PF_PID=""
      cleanup_pf() {
        if [[ -n "${PF_PID}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
          kill "$PF_PID" 2>/dev/null || true
          wait "$PF_PID" 2>/dev/null || true
        fi
      }
      trap cleanup_pf EXIT

      echo -e "  Port-forwarding pod ${MODEL_POD} to localhost:8080 (background)..."
      oc port-forward -n "$NS" "pod/${MODEL_POD}" 8080:"$PORT" &>/dev/null &
      PF_PID=$!
      sleep 3

      if kill -0 "$PF_PID" 2>/dev/null; then
        echo -e "  Sending inference request to http://localhost:8080/v1/chat/completions ..."
        if curl -sf --max-time 30 http://localhost:8080/v1/chat/completions \
          -H "Content-Type: application/json" \
          -d "{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"content\": \"Hi, can you tell me about yourself?\", \"role\": \"user\"}]}" >/dev/null 2>&1; then
          echo -e "  ${GREEN}OK: Inference request succeeded.${NC}"
        else
          echo -e "  ${YELLOW}INFO: Inference request failed or timed out. Please check the model and try again.${NC}"
          echo -e "  You can test manually: oc port-forward -n $NS pod/${MODEL_POD} 8080:${PORT}"
          echo -e "  curl http://localhost:8080/v1/chat/completions -H \"Content-Type: application/json\" -d '{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"content\": \"Hi, can you tell me about yourself?\", \"role\": \"user\"}]}'"
          STEP2_FAIL=1
        fi
        cleanup_pf
        trap - EXIT
      else
        echo -e "${YELLOW}  INFO: Port-forward failed. Run manually: oc port-forward -n $NS pod/${MODEL_POD} 8080:${PORT}${NC}"
        STEP2_FAIL=1
      fi
    fi
  fi
  if [[ "${STEP2_FAIL}" -eq 1 ]]; then
    echo -e "${RED}FAIL: Model (chat_generation) check failed. Skipping remaining steps for this instance.${NC}"
    ANY_FAILED=1
    FAILED_THIS_ITERATION=1
    FAILED_ITEMS+=("${NS}/${GORCH_NAME}")
    echo ""
    continue
  fi
  echo ""

  # --- 3. Validate GuardrailsOrchestrator pod status ---
  echo -e "${BOLD}3. Validating GuardrailsOrchestrator pod (namespace ${NS})${NC}"

  POD=$(oc get pods -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep guardrails-orchestrator | head -1)
  if [[ -z "${POD}" ]]; then
    POD=$(oc get pods -n "$NS" -l app.kubernetes.io/name=guardrails-orchestrator --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
  fi
  if [[ -z "${POD}" ]]; then
    POD=$(oc get pods -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -E "orchestrator|${GORCH_NAME}" | head -1)
  fi
  if [[ -z "${POD}" ]]; then
    echo -e "${RED}  FAIL: No guardrails-orchestrator pod found in ${NS}.${NC}"
    STEP3_FAIL=1
  else
    POD_PHASE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null) || true
    POD_READY=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true
    oc get pod "$POD" -n "$NS" -o jsonpath='{.metadata.name}: phase={.status.phase} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null || true
    echo " "
    if [[ "${POD_PHASE}" != "Running" ]] || [[ "${POD_READY}" != "True" ]]; then
      echo -e "${RED}  FAIL: Pod not Running or not Ready (phase=${POD_PHASE}, ready=${POD_READY}).${NC}"
      STEP3_FAIL=1
    fi
  fi
  echo ""

  if [[ "${STEP1_FAIL}" -eq 1 ]] || [[ "${STEP2_FAIL}" -eq 1 ]] || [[ "${STEP3_FAIL}" -eq 1 ]]; then
    ANY_FAILED=1
    FAILED_THIS_ITERATION=1
  fi

  # --- 4. Check otelExporter and back up if present ---
  echo -e "${BOLD}4. Checking otelExporter and backing up if present (namespace ${NS}, CR ${GORCH_NAME})${NC}"

  OTEL_SPEC=$(oc get guardrailsorchestrator -n "$NS" "$GORCH_NAME" -o jsonpath='{.spec.otelExporter}' 2>/dev/null || true)
  OTEL_HAS_FIELDS=0
  if echo "$OTEL_SPEC" | grep -q .; then
    if command -v jq &>/dev/null; then
      [[ $(echo "$OTEL_SPEC" | jq -r 'keys | length' 2>/dev/null) -gt 0 ]] && OTEL_HAS_FIELDS=1
    else
      # Without jq: treat as having fields if not literally {}
      [[ "$OTEL_SPEC" != "{}" ]] && [[ "$(echo "$OTEL_SPEC" | tr -d ' \n')" != "{}" ]] && OTEL_HAS_FIELDS=1
    fi
  fi
  if [[ "${OTEL_HAS_FIELDS}" -eq 1 ]]; then
    echo -e "  ${YELLOW}WARNING: spec.otelExporter uses deprecated field names.${NC}"
    BACKUP_FILE="${BACKUP_DIR}/${NS}_${GORCH_NAME}_otelExporter_$(date +%Y%m%d_%H%M%S).json"
    if command -v jq &>/dev/null; then
      echo "$OTEL_SPEC" | jq . > "$BACKUP_FILE" 2>/dev/null || echo "$OTEL_SPEC" > "$BACKUP_FILE"
    else
      echo "$OTEL_SPEC" > "$BACKUP_FILE"
    fi
    echo -e "  Backed up to: ${CYAN}${BACKUP_FILE}${NC}"
  fi

  # Check if OpenTelemetry and Tempo operators are installed (cluster-wide)
  OTEL_OP_NS=$(oc get csv -A --no-headers 2>/dev/null | grep -i 'opentelemetry-operator' | awk '{print $1}' | head -1) || true
  TEMPO_OP_NS=$(oc get csv -A --no-headers 2>/dev/null | grep -iE 'tempo-operator' | awk '{print $1}' | head -1) || true
  if [[ -n "${OTEL_OP_NS}" ]]; then
    echo
  else
    echo -e "  ${YELLOW}INFO: OpenTelemetry operator not installed${NC}"
  fi
  if [[ -n "${TEMPO_OP_NS}" ]]; then
    echo
  else
    echo -e "  ${YELLOW}INFO: Tempo operator not installed${NC}"
  fi


  if [[ "${OTEL_HAS_FIELDS}" -eq 1 ]]; then
    if [[ -z "${OTEL_OP_NS}" ]] || [[ -z "${TEMPO_OP_NS}" ]]; then
      echo -e "  ${RED}FAIL: spec.otelExporter is set but OpenTelemetry or Tempo operator is not installed.${NC}"
      STEP4_FAIL=1
    fi
  fi

  if [[ "${STEP4_FAIL}" -eq 1 ]]; then
    ANY_FAILED=1
    FAILED_THIS_ITERATION=1
  fi
  if [[ "${FAILED_THIS_ITERATION}" -eq 1 ]]; then
    FAILED_ITEMS+=("${NS}/${GORCH_NAME}")
  fi
  echo ""
done

echo -e "${BOLD}=== Pre-upgrade check complete ===${NC}"
echo ""
if [[ "${ANY_FAILED}" -eq 1 ]]; then
  echo -e "${BOLD}Summary: The following namespace/instance(s) had failures:${NC}"
  if [[ ${#FAILED_ITEMS[@]} -gt 0 ]]; then
    for failed in "${FAILED_ITEMS[@]}"; do
      echo -e "  ${RED}${failed}${NC}"
    done
  fi
  exit 1
else
  echo -e "${GREEN}Summary: All GuardrailsOrchestrator instances are healthy.${NC}"
  exit 0
fi
