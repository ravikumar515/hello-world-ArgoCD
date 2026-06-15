#!/usr/bin/env bash
set -euo pipefail

# Refresh the short-lived AWS credentials consumed by External Secrets Operator.
#
# Optional environment overrides:
#   AWS_PROFILE_NAME=ava-mars-stage
#   AWS_ACCOUNT_ID=776389595347
#   AWS_ROLE_NAME=engineer
#   KUBECTL="sudo kubectl"
#   GENERATE_AWS_SESSION=false

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-ava-mars-stage}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-776389595347}"
AWS_ROLE_NAME="${AWS_ROLE_NAME:-engineer}"
GENERATE_AWS_SESSION="${GENERATE_AWS_SESSION:-true}"
KUBECTL_CMD="${KUBECTL:-kubectl}"

k() {
  ${KUBECTL_CMD} "$@"
}

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

load_aws_profile_env() {
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN

  AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id --profile "$AWS_PROFILE_NAME")"
  AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE_NAME")"
  AWS_SESSION_TOKEN="$(aws configure get aws_session_token --profile "$AWS_PROFILE_NAME")"

  if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" || -z "${AWS_SESSION_TOKEN}" ]]; then
    echo "AWS profile ${AWS_PROFILE_NAME} does not contain complete temporary credentials." >&2
    exit 1
  fi
}

upsert_aws_creds_secret() {
  local namespace="$1"

  k create namespace "$namespace" --dry-run=client -o yaml | k apply -f -
  k create secret generic aws-ares-creds \
    -n "$namespace" \
    --from-literal=access-key="$AWS_ACCESS_KEY_ID" \
    --from-literal=secret-access-key="$AWS_SECRET_ACCESS_KEY" \
    --from-literal=session-token="$AWS_SESSION_TOKEN" \
    --dry-run=client -o yaml | k apply -f -
}

upsert_bd_updater_runtime_secrets() {
  k create namespace mars --dry-run=client -o yaml | k apply -f -
  k create secret generic secret-bd-updater-aws-access-key-id \
    -n mars \
    --from-literal=password="$AWS_ACCESS_KEY_ID" \
    --dry-run=client -o yaml | k apply -f -
  k create secret generic secret-bd-updater-aws-secret-access-key \
    -n mars \
    --from-literal=password="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | k apply -f -
}

annotate_if_present() {
  local namespace="$1"
  local name="$2"

  if k get externalsecret "$name" -n "$namespace" >/dev/null 2>&1; then
    k annotate externalsecret "$name" -n "$namespace" "force-sync=$(date +%s)" --overwrite
  fi
}

require_cmd aws
require_cmd kubectl

if [[ "$GENERATE_AWS_SESSION" == "true" ]]; then
  if command -v sl >/dev/null 2>&1; then
    log "Generating AWS session for ${AWS_PROFILE_NAME}"
    sl aws session generate \
      --role-name "$AWS_ROLE_NAME" \
      --account-id "$AWS_ACCOUNT_ID" \
      --profile "$AWS_PROFILE_NAME"
  else
    echo "Command 'sl' not found. Skipping session generation and using existing AWS profile ${AWS_PROFILE_NAME}." >&2
  fi
fi

log "Validating AWS profile ${AWS_PROFILE_NAME}"
aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" >/dev/null
load_aws_profile_env

log "Updating aws-ares-creds in Kubernetes"
for namespace in external-secrets argocd mars; do
  upsert_aws_creds_secret "$namespace"
done

log "Updating bd-updater runtime AWS credential secrets"
upsert_bd_updater_runtime_secrets

log "Forcing ExternalSecret refresh where resources already exist"
annotate_if_present argocd bitdefender-ecr-helm-repo
annotate_if_present mars ecr-regcred
annotate_if_present mars bitdefender-secrets
annotate_if_present mars bd-updater-aws-access-key-id
annotate_if_present mars bd-updater-aws-secret-access-key
annotate_if_present mars amp-scanner-gen-secrets
annotate_if_present mars amp-scanner-gen-monitor-secrets
annotate_if_present mars avira-secrets
annotate_if_present mars scanning-service-secrets

log "Current ExternalSecret status"
if k get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  k get externalsecret -A
else
  echo "ExternalSecret CRD is not installed yet."
fi
