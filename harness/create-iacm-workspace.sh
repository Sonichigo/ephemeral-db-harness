#!/usr/bin/env bash
###############################################################################
# Create or update the ephemeral-db IaCM workspace, idempotently.
#
# Stages 1 and 3 of harness/pipeline-ephemeral-db-ci.yaml are IACM stages that
# both point at one workspace. The workspace is where the Terraform actually
# lives as far as Harness is concerned: it holds the repo coordinates, the
# provisioner version, the Terraform variables, and the state. Clicking it
# together in the UI works once; it does not survive a new project, a new
# account, or the person who did it leaving. Hence a script.
#
# VERIFICATION STATUS — READ THIS BEFORE TRUSTING ANY LINE BELOW
#   This script has been run against a real Harness account on app.harness.io
#   and created a workspace on the first attempt. What that run settled:
#     - the base path. https://app.harness.io/gateway/iacm/api is correct
#       (so is /iacm/api). The [UNVERIFIED] marker that used to sit on
#       IACM_BASE is gone because of this.
#     - the whole request body. The server echoed back provisioner=terraform,
#       provisioner_version=1.5.7, provider_connector resolved to a
#       type: k8scluster connector, repository_path=terraform/, all three
#       terraform_variables with db_password as value_type: secret, and
#       environment_variables: {}. Maps-not-arrays and the `kind` field are
#       therefore confirmed, not inferred.
#     - the workspace it created then ran: stage 1 provisioned and stage 3
#       destroyed, both green, and its Resources tab listed 10 resources.
#
#   What that run did NOT settle, because the path was never taken:
#     - the PUT/update branch. Only the POST/create branch has run.
#     - the KUBE_FALLBACK=1 branch and every field it adds.
#     - the accepted values of `provisioner` and `provisioner_version` beyond
#       the one pair used (terraform / 1.5.7).
#
#   Lines marked [SPEC]        come from the published Workspaces OpenAPI spec
#                              and are quoted accurately.
#   Lines marked [UNVERIFIED]  are things neither the spec nor that run
#                              settled. They are the places to look first when
#                              this returns a 400 or a 404.
#
# The one thing to do with the result: the workspace identifier this creates is
# what goes into <<IACM_WORKSPACE_ID>> in harness/pipeline-ephemeral-db-ci.yaml
# — in BOTH stage 1 (Provision Ephemeral DB) and stage 3 (Destroy Ephemeral
# DB). They must be the same workspace. Two workspaces means stage 3 plans a
# destroy against empty state, reports "No changes", exits green, and leaves
# the database running. That is the silent-leak failure mode this repo keeps
# coming back to.
#
# Usage:
#   HARNESS_PAT=... HARNESS_ACCOUNT_ID=... HARNESS_ORG=... HARNESS_PROJECT=... \
#   REPO_CONNECTOR=... REPO_NAME=... PROVIDER_CONNECTOR=... \
#     ./harness/create-iacm-workspace.sh
#
# DRY_RUN=1 prints the request body and makes no HTTP call, which is the only
# part of this script anyone has actually been able to test:
#
#   DRY_RUN=1 ./harness/create-iacm-workspace.sh
###############################################################################
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

###############################################################################
# Dependencies. Both are hard requirements: curl makes the calls and jq builds
# the body. jq rather than printf because every value here comes from the
# environment — a CA certificate with embedded newlines, a repo path, a secret
# identifier — and hand-rolled JSON turns any of those into either invalid JSON
# or, worse, valid JSON with the wrong contents.
###############################################################################
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "$tool is not on PATH and is required (install it, then re-run)"
done

###############################################################################
# Inputs.
#
# Everything required is collected and reported in ONE pass. The obvious
# implementation is ${VAR:?message} per variable, which fails on the first one
# and makes the caller re-run the script once per missing value. With seven
# required inputs that is seven round trips to find out you were missing three.
###############################################################################
DRY_RUN="${DRY_RUN:-0}"

# Identity and display name of the workspace. WS_ID is a Harness identifier, so
# keep it to letters, digits and underscores — hyphens are fine in WS_NAME and
# are what the rest of this repo uses, which is why the two differ.
WS_ID="${WS_ID:-ephemeral_db}"
WS_NAME="${WS_NAME:-ephemeral-db}"

# [UNVERIFIED] Accepted values of `provisioner`. The spec types it as a bare
# string with no enum, so a typo validates and fails server-side. "terraform"
# and "opentofu" are the two the docs discuss.
PROVISIONER="${PROVISIONER:-terraform}"

# Terraform 1.6 and later are BSL-licensed and NOT supported by IaCM, so this
# must stay at 1.5.x or move to OpenTofu. terraform/.terraform.lock.hcl in this
# repo was generated by 1.5.7, which is also the version the Custom-stage
# fallback pins, so keeping both on 1.5.7 means one lock file serves both paths.
# [UNVERIFIED] The full list of accepted provisioner_version strings. The spec
# does not publish one.
PROVISIONER_VERSION="${PROVISIONER_VERSION:-1.5.7}"

# Where the Terraform comes from. REPO_PATH points at terraform/ because that
# is where main.tf lives; the IaCM plugin fetches the repo itself, which is why
# the IACM stages set cloneCodebase: false and the pipeline has no
# properties.ci.codebase block.
#
# [UNVERIFIED] These repository_* fields are not in CreateWorkspaceRequest's
# required list, so unlike provider_connector they will not announce themselves
# if a name is wrong. We could not test what a wrong one does.
REPO_CONNECTOR="${REPO_CONNECTOR:-}"    # e.g. account.github_conn
REPO_NAME="${REPO_NAME:-}"              # e.g. my-org/ephemeral-db-harness
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_PATH="${REPO_PATH:-terraform/}"

# [SPEC] provider_connector is in CreateWorkspaceRequest.required. It is
# required even though this Terraform needs no cloud credentials at all — there
# is no AWS, no GCP, nothing to authenticate to beyond the Kubernetes API. Pass
# the Kubernetes connector for the target cluster and move on. Omitting it
# because "we have no cloud provider" is a 400 and is ISSUES.md issue 7.
PROVIDER_CONNECTOR="${PROVIDER_CONNECTOR:-}"

# A Harness SECRET IDENTIFIER, never the password itself. See the
# terraform_variables block for what happens if you pass plaintext.
# Project-scoped secrets are bare identifiers; account- and org-scoped ones
# need an "account." or "org." prefix. SETUP.md creates this as
# ephemeral_db_password.
DB_PASSWORD_SECRET="${DB_PASSWORD_SECRET:-ephemeral_db_password}"

# Terraform variables whose defaults in terraform/variables.tf are already
# right for this repo, overridable here when they are not.
#
# build_service_account defaults to "default" deliberately. The IACM stages
# omit serviceAccountName, so the build pod runs as the build namespace's
# "default" ServiceAccount, and that is the only subject
# terraform/bootstrap/provisioner-rbac.yaml binds the provisioner ClusterRole
# to. Name anything else here and build-access.tf grants permissions to a
# ServiceAccount that nothing runs as, while the pod that does run gets a
# Forbidden on apply with no hint in either file about why.
BUILD_NAMESPACE="${BUILD_NAMESPACE:-harness-builds}"
BUILD_SERVICE_ACCOUNT="${BUILD_SERVICE_ACCOUNT:-default}"

# Left empty means "do not send it, let terraform/variables.tf decide". Set
# either one only if you are deviating from the repo defaults (dbops-ci and
# ephemeral-db). Changing service_name in particular means re-pinning the JDBC
# connector, because that connector cannot take a pipeline expression.
DB_NAMESPACE="${DB_NAMESPACE:-}"
DB_SERVICE_NAME="${DB_SERVICE_NAME:-}"

# VERIFIED. The published spec declares its server as "http://localhost:80", so
# the real prefix is not in the spec and this was a guess for a long time. It is
# not any more: an authenticated GET against
# https://app.harness.io/gateway/iacm/api/orgs/{org}/projects/{proj}/workspaces
# returns HTTP 200 and JSON. https://app.harness.io/iacm/api works too. If this
# script returns a 404 or an HTML sign-in page rather than JSON on a DIFFERENT
# Harness cluster (eu, prod2, …), the host is what changed, not this suffix.
IACM_BASE="${IACM_BASE:-https://app.harness.io/gateway/iacm/api}"

###############################################################################
# The Docker/Cloud credential fallback. OFF by default, and it should stay off.
#
# These three environment variables exist for the Docker and Harness Cloud
# runtimes ONLY, where the provisioner runs as a container on a host rather
# than as a pod in the target cluster and therefore has no ServiceAccount token
# to authenticate with.
#
# On the primary path — infrastructure.type KubernetesDirect, which is what
# harness/pipeline-ephemeral-db-ci.yaml uses — the build pod already carries a
# projected ServiceAccount token at
# /var/run/secrets/kubernetes.io/serviceaccount/, which is exactly the identity
# terraform/main.tf's provider block expects when kube_config_path is empty.
# Setting these variables there does not add a fallback, it OVERRIDES working
# in-cluster auth with whatever is in them. A stale KUBE_TOKEN then turns a
# working pipeline into "Unauthorized" with nothing in the diff to explain it.
#
# Three things that cost real time if you get them wrong:
#
#   KUBE_HOST  is a full URI including the scheme: https://1.2.3.4:6443.
#
#   KUBE_CLUSTER_CA_CERT_DATA  is RAW PEM, including the
#   -----BEGIN CERTIFICATE----- lines, despite the _DATA suffix on the name.
#   Base64 is wrong and fails with "unable to load root certificates: unable to
#   parse bytes as PEM block", which reads like a corrupt certificate rather
#   than a wrong encoding.
#
#   KUBE_TOKEN  is the raw JWT, passed here as a secret REFERENCE. On
#   Kubernetes 1.24 and later a ServiceAccount has no auto-created token Secret, and
#   `kubectl create token` defaults to exactly one hour with no warning, so a
#   token pasted into a Harness secret that way starts failing about an hour
#   later and looks like an RBAC or connectivity problem. For a stored
#   credential, create an explicit kubernetes.io/service-account-token Secret —
#   that token has no exp claim. Do not reach for
#   `kubectl create token --duration=8760h` instead: it is silently capped by
#   the apiserver's --service-account-max-token-expiration, which managed
#   EKS/AKS/GKE control planes set.
#
# One trap this script cannot fix for you: the Kubernetes provider ignores
# KUBECONFIG but DOES read KUBE_CONFIG_PATH and KUBE_CONFIG_PATHS, and because
# kube_config_path="" leaves config_path null, a kubeconfig found through either
# of those env vars SILENTLY WINS over KUBE_TOKEN — proven with a deliberately
# invalid KUBE_TOKEN, which still produced "No changes. Your infrastructure
# matches the configuration." On the fallback path make sure neither variable
# is present in the runtime's environment. A workspace variable can set a
# value; it cannot reliably unset one.
#
# Also note that validating these with `terraform plan` alone gives a false
# pass: plan on an all-new configuration never contacts the API server, so it
# succeeds with a completely bogus token. Only apply, or a plan that refreshes
# existing state, authenticates.
#
# See terraform/bootstrap/provisioner-rbac.yaml for the optional named
# ServiceAccount and long-lived token Secret this path needs. The default
# bindings there cover the in-cluster path only.
###############################################################################
KUBE_FALLBACK="${KUBE_FALLBACK:-0}"
KUBE_HOST="${KUBE_HOST:-}"
KUBE_CLUSTER_CA_CERT_DATA="${KUBE_CLUSTER_CA_CERT_DATA:-}"
KUBE_TOKEN_SECRET="${KUBE_TOKEN_SECRET:-}"   # secret identifier, not a token

###############################################################################
# Validate inputs. One pass, every missing name reported together.
###############################################################################

# Both of these gate destructive-ish behaviour on a string comparison, so an
# unrecognised spelling must abort rather than silently pick a default. The
# dangerous direction differs for each: a mistyped DRY_RUN would write to a
# live account, and a mistyped KUBE_FALLBACK would drop all three Kubernetes
# credentials from the body and skip their required-variable check, producing
# a workspace that looks correct and cannot authenticate.
normalise_flag() {
  local name="$1" val="$2"
  case "${val,,}" in
    1|true|yes|on)   printf '1' ;;
    0|false|no|off)  printf '0' ;;
    *) die "$name=$val is not a recognised boolean (use 1/0, true/false, yes/no, on/off)" ;;
  esac
}
DRY_RUN="$(normalise_flag DRY_RUN "$DRY_RUN")"
KUBE_FALLBACK="$(normalise_flag KUBE_FALLBACK "$KUBE_FALLBACK")"

# Lowercased so the BSL version guard below and the provisioner field itself
# cannot be bypassed by capitalisation.
PROVISIONER="${PROVISIONER,,}"
case "$PROVISIONER" in
  terraform|opentofu) ;;
  *) die "PROVISIONER=$PROVISIONER is not valid (use terraform or opentofu)" ;;
esac

required=(HARNESS_ACCOUNT_ID HARNESS_ORG HARNESS_PROJECT
          REPO_CONNECTOR REPO_NAME PROVIDER_CONNECTOR)

# HARNESS_PAT is only needed for the real calls, so DRY_RUN can run without one
# rather than making you invent a fake token to see the body.
if [[ "$DRY_RUN" != "1" ]]; then
  required+=(HARNESS_PAT)
fi

if [[ "$KUBE_FALLBACK" == "1" ]]; then
  required+=(KUBE_HOST KUBE_CLUSTER_CA_CERT_DATA KUBE_TOKEN_SECRET)
fi

missing=()
for v in "${required[@]}"; do
  # ${!v} is an indirect expansion; the :- keeps it legal under `set -u`.
  [[ -n "${!v:-}" ]] || missing+=("$v")
done

if (( ${#missing[@]} > 0 )); then
  printf 'error: %d required environment variable(s) not set:\n' "${#missing[@]}" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  cat >&2 <<'USAGE'

Set all of them and re-run. Minimum invocation:

  HARNESS_PAT=pat.xxxxx \
  HARNESS_ACCOUNT_ID=your_account_id \
  HARNESS_ORG=your_org_id \
  HARNESS_PROJECT=your_project_id \
  REPO_CONNECTOR=account.github_conn \
  REPO_NAME=my-org/ephemeral-db-harness \
  PROVIDER_CONNECTOR=account.k8s_target_cluster \
    ./harness/create-iacm-workspace.sh

Optional overrides: WS_ID WS_NAME PROVISIONER PROVISIONER_VERSION REPO_BRANCH
REPO_PATH DB_PASSWORD_SECRET BUILD_NAMESPACE BUILD_SERVICE_ACCOUNT DB_NAMESPACE
DB_SERVICE_NAME IACM_BASE DRY_RUN

Docker/Cloud fallback only (do NOT set these for KubernetesDirect):
KUBE_FALLBACK=1 plus KUBE_HOST KUBE_CLUSTER_CA_CERT_DATA KUBE_TOKEN_SECRET
USAGE
  exit 1
fi

# A local guard, not a server-side one. The API would take 1.9.2 happily and
# the failure would arrive inside a run — and for stage 3 that means during
# teardown of real infrastructure, which is the worst place to find out.
case "$PROVISIONER_VERSION" in
  1.[0-5]|1.[0-5].*|0.*) ;;
  *)
    # Not an error on OpenTofu, whose version numbers are its own and are past
    # 1.6 without being BSL-licensed.
    if [[ "$PROVISIONER" == "terraform" ]]; then
      die "PROVISIONER_VERSION=$PROVISIONER_VERSION: IaCM supports Terraform 1.5.x and earlier only (1.6+ is BSL-licensed). Use 1.5.7, or set PROVISIONER=opentofu."
    fi ;;
esac

###############################################################################
# Build the request body.
#
# [SPEC] CreateWorkspaceRequest.required = identifier, name, provider_connector,
#   provisioner, terraform_variables, environment_variables.
#
# [SPEC] terraform_variables and environment_variables are OBJECTS — maps keyed
#   by variable name — NOT arrays. Sending the array of {key,value} objects that
#   every other Harness variables API takes is a 400. This is ISSUES.md issue 7.
#
# [SPEC] environment_variables is required even when you want none. Send {}.
#   Omitting the key is a 400; it is not treated as empty.
#
# [SPEC] Each map value is a Variable {key, value, value_type, kind}, and `kind`
#   is REQUIRED — "tf" for terraform_variables, "env" for environment_variables.
#   This is the one that wastes an afternoon: `kind` appears in
#   Variable.required but is ABSENT from Variable.properties in the workspaces
#   spec (VariableResource has the same hole), and its enum ["env","tf"] is only
#   defined in the separate variables API spec. So a reader who has already
#   fixed provider_connector and the map-vs-array problem gets a third 400 with
#   no field in the spec they are reading to explain it.
#
# [SPEC] value_type enum: string | secret | boolean | json | number.
#   value_type "secret" means `value` is a REFERENCE to an existing Harness
#   secret. Passing the literal password there does not create a secret holding
#   the password — it stores the password AS the secret's identifier, and the
#   lookup then fails on a name that is itself the thing you were hiding.
#
# The two jq helpers exist so neither `kind` nor the key duplication can drift:
# the map key and the Variable's `key` field are generated from one argument.
###############################################################################
# Written as a full `if` rather than `[[ ... ]] && x=true`, because under
# `set -e` the short form exits the script whenever the test is false.
if [[ "$KUBE_FALLBACK" == "1" ]]; then
  fallback_json=true
else
  fallback_json=false
fi

body="$(
  jq -n \
    --arg id "$WS_ID" \
    --arg name "$WS_NAME" \
    --arg prov "$PROVISIONER" \
    --arg pver "$PROVISIONER_VERSION" \
    --arg pconn "$PROVIDER_CONNECTOR" \
    --arg rconn "$REPO_CONNECTOR" \
    --arg repo "$REPO_NAME" \
    --arg branch "$REPO_BRANCH" \
    --arg path "$REPO_PATH" \
    --arg pwsecret "$DB_PASSWORD_SECRET" \
    --arg buildns "$BUILD_NAMESPACE" \
    --arg buildsa "$BUILD_SERVICE_ACCOUNT" \
    --arg dbns "$DB_NAMESPACE" \
    --arg dbsvc "$DB_SERVICE_NAME" \
    --argjson fallback "$fallback_json" \
    --arg kubehost "$KUBE_HOST" \
    --arg kubeca "$KUBE_CLUSTER_CA_CERT_DATA" \
    --arg kubetok "$KUBE_TOKEN_SECRET" \
    '
    def tfvar($k; $v; $t):  { ($k): { key: $k, value: $v, value_type: $t, kind: "tf"  } };
    def envvar($k; $v; $t): { ($k): { key: $k, value: $v, value_type: $t, kind: "env" } };

    {
      identifier:           $id,
      name:                 $name,
      provisioner:          $prov,
      provisioner_version:  $pver,
      provider_connector:   $pconn,
      repository_connector: $rconn,
      repository:           $repo,
      repository_branch:    $branch,
      git_fetch_type:       "branch",
      repository_path:      $path,

      # The outer parentheses are load-bearing: inside an object constructor jq
      # will not parse a bare `a + b` as the value, and the error it gives is
      # "syntax error, unexpected +, expecting }" with a shell-quoting red
      # herring attached.
      terraform_variables: (
          tfvar("db_password";           $pwsecret; "secret")
        + tfvar("build_namespace";       $buildns;  "string")
        + tfvar("build_service_account"; $buildsa;  "string")
        + (if $dbns  != "" then tfvar("namespace";    $dbns;  "string") else {} end)
        + (if $dbsvc != "" then tfvar("service_name"; $dbsvc; "string") else {} end)
      ),

      environment_variables: (
          if $fallback then
               envvar("KUBE_HOST";                  $kubehost; "string")
             + envvar("KUBE_CLUSTER_CA_CERT_DATA";  $kubeca;   "string")
             + envvar("KUBE_TOKEN";                 $kubetok;  "secret")
          else {} end
      )
    }'
)"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN=1: request body only, no HTTP call made.\n\n' >&2
  printf '%s\n' "$body"
  exit 0
fi

###############################################################################
# Idempotent upsert: GET, then POST on 404 or PUT on 200.
#
# [SPEC] org and project are PATH segments, not query parameters, and the
#   account goes in the Harness-Account HEADER. Auth is the x-api-key header.
#
# [UNVERIFIED] Whether Harness-Account alone is enough, or accountIdentifier
#   must ALSO be a query parameter. Most Harness gateway routes want the query
#   param, the IaCM spec declares the header, and we could not test which the
#   gateway actually enforces. Both are sent. If that turns out to be a problem
#   — a 400 complaining about an unexpected parameter — drop the query string
#   first, since the header is the documented one.
###############################################################################
WS_URL="$IACM_BASE/orgs/$HARNESS_ORG/projects/$HARNESS_PROJECT/workspaces"
QS="accountIdentifier=$HARNESS_ACCOUNT_ID"

# An explicit XXXXXX template rather than `mktemp -t prefix`: the short form is
# a BSD-ism that macOS accepts and GNU coreutils rejects, so it would work on a
# laptop and fail inside a Linux container.
resp="$(mktemp "${TMPDIR:-/tmp}/iacm-workspace.XXXXXX")"
trap 'rm -f "$resp"' EXIT

# The PAT goes to curl through a config file on stdin (-K-), not as a -H
# argument. Anything on curl's argv is readable from the process table by any
# other user on the host for the lifetime of the call, and a Harness PAT is a
# full-account credential. The other headers would be harmless on argv but are
# kept together for legibility.
req() {
  local method="$1" url="$2"
  shift 2
  printf 'header = "x-api-key: %s"\nheader = "Harness-Account: %s"\nheader = "Content-Type: application/json"\nheader = "Accept: application/json"\n' \
    "$HARNESS_PAT" "$HARNESS_ACCOUNT_ID" \
    | curl -sS --max-time 60 -o "$resp" -w '%{http_code}' \
        -X "$method" "$url" -K- "$@"
}

# The response may not be JSON at all — an HTML sign-in page is the signature
# of a wrong base path — so fall back to raw bytes rather than swallowing it.
show() { jq . "$resp" 2>/dev/null || head -c 2000 "$resp"; printf '\n'; }

# 401 and 403 are reachable from two places, and the advice is the same from
# both, so it lives in one function. 403 in particular is not "wrong token" —
# the token got through — it is "this token is not allowed to do this".
auth_failed() {
  printf 'error: HTTP %s from the gateway.\n' "$1" >&2
  printf 'The request reached Harness and was rejected on authorisation, so\n' >&2
  printf 'this is a permissions problem rather than a connectivity one. Check\n' >&2
  printf 'that HARNESS_PAT still exists and has not expired, that it carries\n' >&2
  printf 'IaCM workspace create/edit permission in org %s / project %s,\n' \
    "$HARNESS_ORG" "$HARNESS_PROJECT" >&2
  printf 'and that HARNESS_ACCOUNT_ID is the account the PAT belongs to.\n' >&2
  printf 'response body:\n' >&2
  show >&2
  exit 1
}

if ! code="$(req GET "$WS_URL/$WS_ID?$QS")"; then
  die "curl could not complete the request to $WS_URL/$WS_ID (DNS, proxy, or egress?). Nothing was changed."
fi

case "$code" in
  200)
    printf 'workspace %s already exists — updating it (PUT).\n' "$WS_ID"
    # [UNVERIFIED] That PUT accepts the same body shape as POST. The spec
    # exposes "Update workspace" at PUT .../workspaces/{workspace} but does not
    # publish a distinct request schema, so this reuses the create body. If the
    # PUT 400s while a POST of the same body would have worked, this is the
    # line to suspect.
    if ! code="$(req PUT "$WS_URL/$WS_ID?$QS" --data "$body")"; then
      die "curl could not complete the PUT to $WS_URL/$WS_ID."
    fi ;;
  404)
    printf 'workspace %s does not exist — creating it (POST).\n' "$WS_ID"
    if ! code="$(req POST "$WS_URL?$QS" --data "$body")"; then
      die "curl could not complete the POST to $WS_URL."
    fi ;;
  401|403)
    auth_failed "$code" ;;
  *)
    printf 'error: unexpected HTTP %s probing %s\n' "$code" "$WS_URL/$WS_ID" >&2
    printf 'If this is a 404 on an HTML page rather than JSON, IACM_BASE is\n' >&2
    printf 'probably wrong for this Harness cluster — see the note on IACM_BASE.\n' >&2
    printf 'response body:\n' >&2
    show >&2
    exit 1 ;;
esac

case "$code" in
  200|201|204)
    # A 2xx is not on its own proof the workspace was written. If IACM_BASE is
    # wrong, a gateway or SPA route can answer 200 with an HTML sign-in page,
    # and reporting that as success would be followed by wire-it-up
    # instructions for a workspace that does not exist. So require the response
    # to be JSON that echoes back the identifier we asked for. 204 carries no
    # body by design, so it is re-read instead of parsed.
    if [[ "$code" == 204 ]]; then
      code="$(req GET "$WS_URL/$WS_ID?$q")"
      [[ "$code" == 200 ]] || die "write returned 204 but the workspace could not be read back (HTTP $code)"
    fi
    if ! jq -e --arg id "$WS_ID" '.identifier == $id' "$resp" >/dev/null 2>&1; then
      printf 'error: HTTP %s, but the response is not JSON describing workspace %s.\n' "$code" "$WS_ID" >&2
      printf 'IACM_BASE is probably wrong — a gateway route can answer 200 with\n' >&2
      printf 'an HTML page. Response body:\n' >&2
      show >&2
      exit 1
    fi
    printf 'ok (HTTP %s). Workspace response:\n' "$code"
    show
    cat <<EOF

Next: put this identifier into harness/pipeline-ephemeral-db-ci.yaml, replacing
<<IACM_WORKSPACE_ID>> in BOTH stage 1 and stage 3:

    $WS_ID

Both stages must name the same workspace. If stage 3 points somewhere else it
plans a destroy against empty state, prints "No changes. No objects need to be
destroyed.", exits green, and leaves the namespace Active.

The Resources tab, drift detection and cost estimation come from the workspace,
not from the pipeline, so they will not appear until a run has populated state.
EOF
    ;;
  401|403)
    auth_failed "$code" ;;
  400)
    printf 'error: HTTP 400 writing the workspace. Response:\n' >&2
    show >&2
    cat >&2 <<'HINT'

A 400 here is almost always the body, and there are four known causes:
  - provider_connector missing (it is required even with no cloud provider)
  - terraform_variables / environment_variables sent as arrays, not maps
  - a Variable missing its "kind" field ("tf" or "env") — which the workspaces
    spec lists as required but does not document in Variable.properties
  - environment_variables omitted entirely instead of sent as {}
This script sends all four correctly, so if you see a 400, compare the body
printed by DRY_RUN=1 against the message above before editing anything.
HINT
    exit 1 ;;
  *)
    printf 'error: write failed (HTTP %s). Response:\n' "$code" >&2
    show >&2
    exit 1 ;;
esac
