# Issues found by running this repo against a real cluster

The README says the Terraform has never been applied and that
`build-access.tf`, the reaper CronJob, `GitClone`, and `DBSchemaApply` are
"unproven in situ". This document is the result of proving them. Every issue
below was reproduced; each entry gives the cause rather than just the symptom,
because in four cases the symptom already had a troubleshooting entry in
SETUP.md and that entry named the wrong cause.

**What was run.** minikube v1.32.0 on colima (arm64), Postgres 16.4, Flyway 10.x
via `plugins/drone-flyway:1.3.0-11.11.2`, Liquibase 4.29. Harness delegate
`local-minikube` running inside the cluster. Database namespace `dbops-ci`;
build pods in a separate **unprivileged** namespace `harness-builds`.

There are three distinct bodies of evidence behind this document and they are not
interchangeable, so they are kept apart throughout. In order of how much they
settle: Custom stages on a real account, Terraform run directly on minikube, and
— newest, and the one that supersedes several earlier claims — real IACM stages
on a real account.

*Executed on app.harness.io.* Issues 1-5, 8-16 and issue 6's original symptom
were reproduced by submitting pipelines to a real Harness account against that
cluster, with stages 1 and 3 as **Custom** stages running
`hashicorp/terraform:1.5.7` in a
`KubernetesDirect` step group. All three stages run green that way, from an
empty cluster to a destroyed namespace, on both migration tools:

| Tool | Provision | Migrate | Destroy | Total |
|---|---|---|---|---|
| Flyway | 102s | 146s | 81s | 5m34s |
| Liquibase | 94s | 87s | 52s | 3m56s |

Single-node minikube on a laptop, so treat these as an upper bound on a real
cluster rather than a benchmark. Those timings are the **Custom-stage** path,
and the Liquibase row in particular is the old `Run`-step workaround from
issue 13 — it is faster partly because it skips the Database DevOps machinery
the Flyway row pays for. Both tools now run through `DBSchemaApply`, so expect
the two rows to converge; they have not been re-timed.

*Executed directly on minikube, outside Harness.* Issue 6's correction — that
IaCM can run this Terraform against a private cluster after all, through
`infrastructure: type: KubernetesDirect` — was verified by running
terraform 1.5.7 in a pod in `harness-builds` as ServiceAccount `default`, with
no kubeconfig and `main.tf` unchanged. That reproduces the *identity* an IaCM
Kubernetes build pod runs as, and it is the part of the claim that could fail
quietly. Details are in issue 6.

*Executed on app.harness.io as IACM stages.* This is the newest tier and it
supersedes an earlier edition of this paragraph, which said the IACM stages had
never run on a Harness account, that no workspace was created and that the
Resources tab had never been seen. All three of those statements are now false.
What has been run, on account `nwHBifh8T2GfffuOx6ORmA`, project
`ephemeral_db_ci`, workspace `ephemeral_db` (provisioner `terraform 1.5.7`),
against the same minikube cluster:

| Check | Result |
|---|---|
| Workspace created via `harness/create-iacm-workspace.sh` | HTTP 200, all fields persisted, first try |
| `type: IACM` + `infrastructure: type: KubernetesDirect` accepted | HTTP 200 on `POST /pipeline/api/pipelines/v2` — settles issue 6 |
| Stage 1 alone | Success. Namespace, `deployment.apps/ephemeral-db 1/1`, `service/ephemeral-db` ClusterIP, reaper CronJob — with **zero** credential configuration, in-cluster ServiceAccount token only |
| Resources tab | 10 resources returned by `/workspaces/ephemeral_db/resources` |
| Stage 3 alone, after stage 1 alone | `dbops-ci` Active → Terminating → **NotFound**. This is the headline acceptance check and it passes |
| Failed migration still destroys | Provision Success, Migrate Failed, Destroy Success, namespace NotFound. Confirms the `when: pipelineStatus: All` on stage 3 |
| Full green pipeline, end to end, Flyway | Twice. IaCM init/plan/apply → wake, wait, seed, `DBOPS_WRAPPER`, Verify Migration → IaCM init/plan-destroy/destroy → NotFound |
| Full green pipeline, end to end, Liquibase | Once, through a real `DBSchemaApply` step rather than the old `Run`-step workaround. Flyway step `Skipped`, namespace NotFound. This retracts issue 13 |

Two things in this tier are still **not** proven, and are called out where they
matter rather than glossed: the workspace **outputs** endpoint could not be
found at all (`/outputs`, `/output`, `/terraform-outputs`, `/state`,
`/state-outputs`, `/latest-state` all 404 — only `/resources` responds), so the
"`jdbc_url` visible in the Resources tab" check is unconfirmed; and the
`KUBE_FALLBACK=1` Docker/Cloud runtime branch has never been executed, because
the Kubernetes runtime worked and there was no reason to fall back.

Several of the issues below (17 onward) were found by reading the pipeline schema
and the Harness docs rather than by running anything; each says which, and those
that have since been executed say so.

The Liquibase run started from nothing — no namespace, empty Terraform state —
and ended with the namespace gone. In each run the other tool's step reports
`Skipped`, so the `when` gating on `MIGRATION_TOOL` is doing what it claims.

An asymmetry described here in an earlier edition — "the Flyway run shows a
schema-to-instance update summary in Harness and the Liquibase run shows none,
because the Liquibase branch bypasses `DBSchemaApply`" — **no longer exists**.
Both branches are now `DBSchemaApply` steps differing only in `migrationType`,
and both appear in the Database DevOps UI. See issue 13, which is a retraction
rather than an issue.

The core claim of the repo holds: the same `ALTER TABLE` succeeds on an empty
database and fails with
`column "status" of relation "orders" contains null values` on the seeded one,
and `baselineOnMigrate` is load-bearing exactly as documented. The issues below
are everything between "the idea is right" and "the pipeline runs".

Ordering: issues 1-16 are the original pass, blockers first (the pipeline cannot
start or cannot pass), then documentation that actively misleads, then design
gaps. Issues 17-22 came later, from moving stages 1 and 3 onto IaCM by reading
the schema and the docs, and are mostly silent-failure traps rather than
blockers — which is why they sit after the original pass and not because they
matter less. Issues 23-28 came last, from actually executing those IaCM stages
on an account; three of them (23, 24, 25) are hard blockers that no amount of
schema validation would have found, which is the argument for the third evidence
tier existing at all.

Entries marked **fixed in this repo** or **applied** are done; the rest are
documentation corrections, upstream platform behaviour, or — in two cases,
issues 6 and 13 — retractions of a conclusion recorded here earlier. Retractions
are kept in place rather than deleted, because both were load-bearing: each one
justified a workaround that is now gone.

---

## 1. `DBSchemaApply` rejects `tag:` under Flyway — the pipeline cannot start

**Where:** `harness/pipeline-ephemeral-db-ci.yaml:250`

```yaml
tag: <+pipeline.executionId>
```

**Symptom:** the pipeline fails at plan creation, before any stage runs:

```
PLAN_CREATION_ERROR: Tag is not supported for flyway migration type
```

**Cause:** `tag` is a Liquibase concept — a label you can later roll back to.
Flyway has no equivalent, so the step schema forbids the field when
`migrationType` is Flyway. The expression is valid and the intent (stamp each
apply with the execution ID) is reasonable; the field simply does not exist on
this code path. It was almost certainly copied from a Liquibase example.

**Fix:** delete the line. Nothing replaces it — Flyway's own
`flyway_schema_history` is the audit trail.

**Severity:** blocker, and the cheapest possible one to have caught. This is a
plan-time schema error, so it fires on any execution attempt regardless of
cluster, credentials, or connectivity. It means the pipeline YAML in this repo
has never been submitted to Harness.

---

## 2. `connectorRef: account.harnessImage` cannot pull public images

**Where:** `harness/pipeline-ephemeral-db-ci.yaml:138, 168, 206, 244, 259` —
all five container steps, plus the sixth container the `DBSchemaApply` step
expands into.

**Symptom:** every step pod sits in `ImagePullBackOff`. The events show the
image rewritten:

```
Failed to pull image "us-docker.pkg.dev/gar-prod-setup/harness-public/postgres:16.4":
  manifest unknown
```

Same for `alpine/k8s:1.30.0` and `plugins/drone-flyway:1.3.0-11.11.2`.

**Cause:** `account.harnessImage` is a built-in connector pointing at
Harness's own Google Artifact Registry, which hosts *Harness's* first-party
step images (`harness/ci-addon`, the delegate, the drone plugins Harness
publishes). It is not a Docker Hub mirror or pull-through cache. Setting it on
a step means "find `postgres:16.4` in Harness's private GAR", and Harness does
not publish `postgres` there.

The trap is that removing the field does not work either. Under Kubernetes
build infrastructure a connector is mandatory, and you get told so twice, in
two different vocabularies at two different times:

```
SCHEMA_VALIDATION_FAILED: steps[4].spec.connectorRef is missing but it is required
```
```
With a Kubernetes cluster build infrastructure, connector ref is required
for stepId: verify_migration
```

**Fix:** a real registry connector. A `DockerRegistry` connector with
`Anonymous` auth against `https://index.docker.io/v2/` is enough for these
public images — that is what the verified run used. Anything shipping this for
real should point at a private registry or a pull-through cache with
credentials, because anonymous Docker Hub is rate-limited per source IP and
every build pod in the cluster shares one. One transient
`Get "https://index.docker.io/v2/": EOF` was observed mid-session, which is
what that limit looks like.

**Severity:** blocker. Six steps, all of them.

---

## 3. `bitnami/kubectl:1.30` no longer exists

**Where:** `harness/pipeline-ephemeral-db-ci.yaml:139` (wake step),
`terraform/variables.tf:79` (`reaper_image` default), and
`SETUP.md:331` (the tuning table row that documents that default).

**Symptom:** `ImagePullBackOff`, `manifest unknown`, in both the wake step and
the reaper pod.

**Cause:** Bitnami retired its free Docker Hub catalog in 2025. The tags moved
to `bitnamilegacy/*` and the images stopped being maintained. This is not a
typo or a version drift — the coordinate is gone, and no amount of registry
configuration recovers it.

The reaper is where this bites hardest, because it fails *silently*. A pipeline
step that cannot pull turns red and someone looks at it. The reaper is a
CronJob: its pod went to `ImagePullBackOff` and its Job sat wedged at `0/1`
for **20 hours** across the session, and because `reaper.tf:67` sets
`concurrency_policy = "Forbid"`, that one stuck Job suppressed every
subsequent tick. The cluster reports a healthy CronJob object the whole time.
Nothing scales to zero, and the only evidence is a cost line at the end of the
month.

**Fix:** `alpine/k8s:1.30.0` for both, verified in situ. Update SETUP.md's
tuning table to match. Note the knock-on effect in issue 4.

Consider also `failed_jobs_history_limit` and an alert on
`kube_job_status_failed` for the reaper — the design's fallback for "the
pipeline never reached teardown" has no fallback of its own, and `Forbid`
converts one bad pod into an indefinite outage.

**Severity:** blocker for the wake step; silent indefinite failure for the
reaper, which is worse.

---

## 4. `GitClone` with `repoName` clones into a subdirectory; the psql steps assume it did not

**Where:** `harness/pipeline-ephemeral-db-ci.yaml:121` sets
`repoName: <<REPO_NAME>>`; the `load_seed` (207) and `verify_migration` (260)
steps then use repo-relative paths.

**Symptom:**

```
psql: error: sql/migrations/V1__baseline.sql: No such file or directory
```

**Cause:** when `GitClone` is given `repoName`, it clones into
`/harness/<repoName>/`, not into `/harness`. The step group's working
directory stays `/harness`. So the clone succeeds — the step is green — and
the *next* step's relative paths resolve one level too high. The failure
surfaces two steps away from its cause, in a step that has nothing wrong with
it.

`cloneDirectory: /harness` looks like the obvious fix and is rejected:

```
/harness is an invalid value for the cloneDirectory field
```

**Fix:** `cd <repoName>` at the top of each step that reads repo files, or set
`cloneDirectory` to a path Harness accepts and reference it consistently.

**SETUP.md is wrong about this one.** Lines 264-268 attribute the error to a
missing `GitClone` step or a wrong `<<REPO_NAME>>`. Both were correct in the
reproduction; the clone step was green and the repo name was right. Following
that entry sends you to re-verify two things that are already fine while the
actual cause — a working directory mismatch the entry never mentions — goes
unexamined. The paragraph's supporting claims are all true (a Custom stage
does not auto-checkout; `properties.ci.codebase` is ignored outside CI
stages), which makes the wrong conclusion more convincing, not less.

---

## 5. `build-access.tf` Role is missing `list` and `watch` — **fixed in this repo**

**Where:** `terraform/build-access.tf:29-33`

**Symptom:** the wake step hangs for its full 180-second timeout and exits 1:

```
deployments.apps "ephemeral-db" is forbidden: User
  "system:serviceaccount:harness-builds:default" cannot list resource
  "deployments" in API group "apps" in the namespace "dbops-ci"
error: timed out waiting for the condition
```

**Cause:** the Role granted `get` and `patch`, reasoning from the commands the
step issues: `kubectl get` needs `get`, `kubectl annotate` needs `patch`. But
the step's third command is `kubectl rollout status`, which does not poll with
`get` — it opens a **watch**, and a watch on a named resource still requires
`list` on the collection. Two verbs missing, and a third gap besides:
`kubectl scale` writes through the `deployments/scale` subresource, which is a
separate RBAC object from `deployments`. The Role never mentioned it.

The RBAC denial is also non-fatal to `rollout status`, which is why this costs
the full timeout: the watch fails, the command keeps waiting for a condition
it can no longer observe, and 180 seconds later it gives up with a message
about timing out rather than about permissions. The real error is the first
line of output and easy to scroll past.

**Fix (applied):** verbs `get, list, watch, patch` on `deployments`, plus a
second rule granting `get, update, patch` on `deployments/scale`. Verified
after apply with `kubectl auth can-i --as=system:serviceaccount:harness-builds:default`
for all four verbs and for `--subresource=scale`.

**SETUP.md is wrong about this one too.** Lines 257-263 blame a
`build_namespace` / `build_service_account` mismatch. This was reproduced with
both variables set correctly and pointing at exactly the namespace the step
group runs in. That entry describes a real and likely misconfiguration, but it
is not the cause of this message, and it is the only cause offered.

**Why this was not caught earlier — and why it stays uncaught.** With
SETUP.md's own defaults (`build_namespace = harness-delegate`,
`build_service_account = default`), the delegate manifest's
`cluster-admin` ClusterRoleBinding covers that ServiceAccount. The build pods
are cluster-admin, `build-access.tf` grants nothing they do not already have,
and the missing verbs are invisible. The bug only appears when build pods run
in a namespace that is *not* the delegate's — which is the correct way to run
them, and the reason this reproduction used a separate `harness-builds`
namespace. Anyone following SETUP.md verbatim gets a working pipeline and an
untested, insufficient Role, and finds out when they tighten their cluster.

---

## 6. IaCM cannot run this Terraform against a private cluster at all — **wrong; corrected below, fixed in this repo**

**Where:** `harness/pipeline-ephemeral-db-ci.yaml:32` and `:292` as authored

**Symptom as authored:** both stages set `runtime.type: Cloud`. Harness Cloud
runners execute on Harness-hosted infrastructure outside your network, and the
Kubernetes provider these stages run expects in-cluster credentials from a
delegate — that is what `terraform/variables.tf` documents ("No cloud
credentials") and what SETUP.md:85-87 restates. A Cloud runner has no delegate
identity and no route to a private API server. The Terraform is written for
in-cluster execution and the pipeline asks for hosted execution.

**Cause, and why the obvious fix does not exist:** the natural correction is to
switch the runtime to delegate-based execution. That option is not there.
`runtime.type` accepts exactly two values, and the platform will tell you so if
you try a third:

```
Invalid yaml: $.pipeline.stages[0].stage.spec.runtime.type: does not have a value
in the enumeration [Docker, Cloud]
```

`Docker` runs the Terraform as a container on the *delegate host*, which is a
different thing from a pod in the cluster in two ways that both matter. It needs
a reachable Docker daemon, which a Kubernetes delegate — itself a pod — does not
have. And a container on a host gets no ServiceAccount token, so
`kube_config_path` stops being the optional escape hatch `variables.tf`
describes and becomes mandatory, along with a kubeconfig mounted somewhere the
delegate can read.

**Fix as first applied:** stages 1 and 3 became Custom stages that run
`hashicorp/terraform:1.5.7` in a `KubernetesDirect` step group — a build pod
*inside* the target cluster, authenticating with its own ServiceAccount token.
That is exactly the identity `main.tf`'s provider block was written for, and it
needs no kubeconfig and no Docker daemon. Three things had to come with it:

- `terraform/backend-kubernetes.tf.example` — remote state in a Secret. IaCM
  managed state for you; a Run step does not. Without shared state the destroy
  stage plans against nothing, prints "no changes", **exits green, and leaves
  the database running** — the precise leak stage 3 exists to prevent, wearing a
  green tick. See also issue 10.
- `terraform/bootstrap/provisioner-rbac.yaml` — the one-time grant that lets the
  build ServiceAccount create what the Terraform manages. See issue 15.
- The lock file now covers `linux_amd64`, `linux_arm64` and `darwin_arm64`.
  A lock file generated on a laptop pins hashes for that platform only, and
  `init` in the build pod then fails on a provider package it is not allowed to
  use.

That workaround works, is verified end to end, and is still in the repo. The
symptom, the cause and the error message above are all accurate and still
reproduce. The **conclusion** — that IaCM could not do this — was not.

---

### Follow-up: the conclusion was wrong, and the error was about the wrong field

The entry originally ended "for a private cluster with a Kubernetes delegate,
neither value works ... it is a gap between what IaCM offers and what this
Terraform needs." That is false. Kubernetes build infrastructure is not selected
through `runtime` at all. It is selected through a **sibling** field,
`infrastructure`, which was never tried because the enum error pointed
confidently at `runtime` and `runtime` is where attention stayed.

The evidence is in Harness's own published pipeline JSON schema,
<https://raw.githubusercontent.com/harness/harness-schema/main/v0/pipeline.json>,
at `definitions.pipeline.stages.iacm`:

- `IACMStageConfigImpl.properties` is `cloneCodebase`, `execution`,
  **`infrastructure`**, `platform`, `runtime`, `serviceDependencies`,
  `sharedPaths`, `workspace`, `moduleId`, `playbooks`, `inventories`,
  `remoteExecutionId`, `description`. So `infrastructure` and `runtime` are two
  different, independent properties of the same stage spec.
- `infrastructure` is a `oneOf` over `DockerInfraYaml`, `HostedVmInfraYaml`,
  **`K8sDirectInfraYaml`**, `UseFromStageInfraYaml` and `VmInfraYaml`.
- `runtime` is a `oneOf` over exactly `CloudRuntime` and `DockerRuntime` — two
  branches, which is precisely why the platform says `[Docker, Cloud]`. The enum
  is complete and the error message is correct. It is simply not the field that
  chooses a Kubernetes cluster.
- `K8sDirectInfraYamlSpec.required` is `[connectorRef, namespace]`. It also
  accepts `serviceAccountName`, `automountServiceAccountToken`, `os`,
  `harnessImageConnectorRef`, `podSpecOverlay`, `volumes`, `labels`,
  `annotations`, `initTimeout`, `imagePullPolicy`, `runAsUser`, `nodeSelector`,
  `tolerations`, `priorityClassName`, `containerSecurityContext` and `hostNames`.
- `IACMStageConfigImpl.required` is `["execution"]` only. `workspace` is **not**
  required, which has its own consequences — see issue 17.
- `delegateSelectors` is a property of `IACMStageNode`, at **stage** level
  alongside `spec`, not of `IACMStageConfigImpl`. Putting it under `spec:`
  validates and is then ignored; also issue 17.

Reproduced locally against that schema with `jsonschema`: a stage carrying
`runtime.type: Kubernetes` fails with

```
'Kubernetes' is not one of ['Docker', 'Cloud']
```

at `branch[properties/runtime/oneOf/0/allOf/0/properties/type/enum]` — the same
error the server gave, from the same enum, confirming both that the enum error is
real and that it is about a field that was never the right one to change.

The Harness docs say so directly, in
`/infrastructure-as-code-management/platform/platform-integrations/delegate.md`:

```
Set up your build infrastructure just as you would for Harness CI. ... Harness
Cloud, Kubernetes cluster, and local runner (Docker) build infrastructures are
supported.
```

What made this easy to miss is that the same page shows YAML for the Cloud and
Docker **runtime** blocks and never shows the Kubernetes one. So the only
concrete examples on the page are the two the enum lists, and the sentence that
contradicts the enum reads like marketing copy until you check the schema.

**Fix (applied, replacing the one above):** stages 1 and 3 in
`harness/pipeline-ephemeral-db-ci.yaml` are `type: IACM` stages with
`infrastructure: type: KubernetesDirect`. The IaCM Terraform plugin then runs in
a build **pod inside the target cluster** with a mounted ServiceAccount token —
exactly the identity `main.tf`'s provider block expects when `kube_config_path`
is empty. No `KUBE_HOST`, no `KUBE_TOKEN`, no `KUBE_CLUSTER_CA_CERT_DATA`, no
kubeconfig mount, and **no functional change to `main.tf`**. The repo gets the
Resources tab, drift detection, cost estimation and a gateable plan artifact
without giving up in-cluster identity. Stage 2 is untouched.

Two details that are load-bearing and look like boilerplate.
`automountServiceAccountToken: true` is set explicitly: it is the platform
default, but without that token the provider has no credentials and
`kube_config_path` stops being optional, so the line is there to document the
dependency rather than to change behaviour. And `serviceAccountName` is
deliberately **omitted**, so the pod runs as the namespace `default`
ServiceAccount — the exact subject `terraform/bootstrap/provisioner-rbac.yaml`
binds. Naming any other ServiceAccount there produces a `Forbidden` apply with
nothing in the YAML to hint at why.

**What was proven, precisely.** terraform 1.5.7 in a pod in `harness-builds` as
ServiceAccount `default`, no kubeconfig, `main.tf` unchanged, on minikube
v1.32.0 linux/arm64. Four pod runs — two full applies of 10 resources and two
full destroys of 10 — so **40 resource operations with zero `Forbidden`
errors**. The pod had the projected token at
`/var/run/secrets/kubernetes.io/serviceaccount/` (`token`, `ca.crt`,
`namespace`) and `KUBERNETES_SERVICE_HOST=10.96.0.1`. The provider resolved to
`hashicorp/kubernetes` v2.38.0 from the committed lock file. Postgres reached
Ready and `psql` connected over the exact `jdbc_url` output
(`jdbc:postgresql://ephemeral-db.dbops-ci-v1.svc.cluster.local:5432/app_test`),
reporting `PostgreSQL 16.4 (Debian 16.4-1.pgdg120+2) on aarch64-unknown-linux-gnu`.
`build-access.tf` and `reaper.tf` applied cleanly, the reaper CronJob was created
(`*/10 * * * *`, `SUSPEND=False`, `Forbid`), and `harness.io/last-used` got a
real value from the `timestamp()` fallback of issue 10
(`2026-10-07T05:21:57Z`). Destroy from a *separate* pod through shared state
removed all 10 resources and left `kubectl get ns dbops-ci-v1` at `NotFound`.

Two things that proof does **not** cover, stated plainly because the distinction
is the whole point of this document. The reaper *script* was not exercised — the
CronJob object was created, no tick was awaited, so nothing about the reaper
logic was re-verified here. On the other hand, 40 operations without a single
denial does say something load-bearing:
`terraform/bootstrap/provisioner-rbac.yaml`, including the
`deployments/scale` grant added in issue 15, is sufficient **as written** for
this path. No RBAC change was needed for it.

**What was not proven at all:** no Harness account or PAT was available, so the
IACM stages were never executed on app.harness.io. They are
**schema-validated only**, plus the equivalent-identity proof above. The
workspace was never created and the Resources tab was never seen. This is a
strong argument that the path works, not a green run. See issue 17 for why
"schema-validated" is a weaker statement than it sounds.

**What came off the pipeline on the IaCM path.** Two blocks that the Custom
stages needed and IaCM makes wrong:

- The `cp backend-kubernetes.tf.example backend-kubernetes.tf` steps are gone.
  IaCM owns state, and that is what removes the failure mode those steps existed
  to prevent. Shared state is load-bearing: a fresh pod with **local** state
  prints `No changes. No objects need to be destroyed.` and exits 0 while the
  namespace stays `Active` — the precise leak stage 3 exists to prevent, wearing
  a green tick. That was reproduced during this round, not assumed. See also
  issue 10. A stray backend block left inside the workspace's `terraform/` would
  divert state away from the platform and bring the whole failure mode back, so
  `terraform/backend-kubernetes.tf.example` stays in the repo with a header
  saying it is for the Custom-stage fallback only; see issue 20 for a collision
  in it.
- The `CUSTOM_CA_PEM_B64` pipeline variable and the shell that appended a CA to
  the container trust store are gone from the main pipeline, because no stage
  left in it uses them. The IaCM-native equivalent is the workspace environment
  variable `PLUGIN_CA_CERT_PATH`, which is **not** a drop-in swap — see issue 14.

**Both paths are kept.** The Custom-stage variant of stages 1 and 3 is preserved
verbatim in `harness/custom-stages.yaml.example`, including the CA-bundle shell,
the backend copy and the apply retry. That is the path with a green run behind
it, so it is the right choice for anyone who needs a working pipeline today or
whose account does not have IaCM. `harness/iacm-stages.yaml.example` is deleted:
its entire premise was that the IaCM stages could not be the real pipeline, and
that premise is what this follow-up corrects.

The three-platform lock file from the original fix survives unchanged and still
matters, because the IaCM plugin runs in a pod too. One thing to add to that
bullet, measured this round: a complete lock file does not make `init`
offline-capable. With egress blackholed, `init` still fails with

```
Error: Failed to query available provider packages
... could not connect to registry.terraform.io
```

The lock file pins *which* provider and *which* hashes; it does not remove the
network dependency. `PLUGIN_BINARY_DIR` does not close that gap either — it
pre-bakes the terraform or tofu **binary** only, providers are still fetched
during `init`, and it degrades silently: "If none of the binaries match, the
plugin downloads the required version at runtime instead". A genuine air gap
needs a provider mirror or an image with the providers baked in.

**Severity as authored:** believed to be the entire provision/destroy half of the
pipeline. In fact a two-line YAML fix that was never found, which cost the
pipeline its Resources tab, drift detection and plan gate for no reason. The
Custom-stage workaround built in response is sound and verified end to end — see
"What was verified working" — so nothing shipped broken; the cost was a capability
silently given up on the strength of a correct error message about the wrong
field.

---

## 7. IaCM workspace creation returns 400 three times over, and the spec explains only two of them

**Symptom:** `POST .../iacm/api/.../workspaces` returns 400. Fix the first
cause and it returns 400 again. Fix the second and it returns 400 a third time,
naming a field that does not appear in the request schema at all.

**Cause:** `CreateWorkspaceRequest.required` is `identifier`, `name`,
`provider_connector`, `provisioner`, `terraform_variables`,
`environment_variables`. Three of those are traps:

1. **`provider_connector` is required** regardless of whether the Terraform
   needs cloud credentials. SETUP.md:85-87 says "there are no cloud credentials
   to supply, because the provider uses the delegate's in-cluster identity" —
   true of the Terraform, false of the workspace form. Use the Kubernetes
   connector for the target cluster.
2. **`terraform_variables` and `environment_variables` are objects**, maps keyed
   by variable name. An array — the shape that reads naturally for a variable
   *list*, and the shape most Terraform tooling uses — is a 400. And
   `environment_variables` is required even when you want none: send `{}`.
   Omitting it is a 400.
3. **Every map value needs a `kind`.** Each value is a `Variable`
   `{key, value, value_type, kind}`, where `kind` is `"tf"` for
   `terraform_variables` and `"env"` for `environment_variables`.

The third one is worse than an ordinary missing required field, and it is the
reason this entry was rewritten. In the workspaces OpenAPI spec, `kind` appears
in `Variable.required` but is **absent from `Variable.properties`** — the same
inconsistency is present in `VariableResource` — and its enum `["env", "tf"]` is
defined only in the separate variables API spec. So a reader who has already
worked out `provider_connector` and the map-versus-array problem gets a third
400 and the request schema in front of them names no field that could explain
it. The field is required by a document that does not describe it.

Two more details that cost time: `value_type` is an enum of `string`, `secret`,
`boolean`, `json`, `number`, and `value_type: secret` takes a **reference** to a
Harness secret, not plaintext. Passing a literal password there stores the
password as the secret's identifier.

One constraint on `provisioner` that is easy to trip over later rather than at
creation time: IaCM supports OpenTofu, or Terraform **1.5.x or earlier**.
Terraform 1.6+ is BSL-licensed and not supported, which is why this repo pins
1.5.7 everywhere. Related, and a genuine trap: the per-command minimum-version
table in the Harness docs — `init`/`plan`/`apply`/`destroy`/`plan-destroy` at
1.6+, `removed` at 1.7+ — is an **OpenTofu** table. Reading it as applying to a
Terraform 1.5.7 workspace makes the whole configuration look unsupported. There
is no equivalent published table for Terraform.

The request shape itself is also easy to get wrong, because the obvious guess is
query parameters: `org` and `project` are **path** segments
(`/api/orgs/{org}/projects/{project}/workspaces`), the account goes in the
**`Harness-Account` header**, and auth is the `x-api-key` header.

**Fix:** `harness/create-iacm-workspace.sh` now does this, so the working shape
is committed rather than rediscovered; SETUP.md documents the provider connector
as a prerequisite. Related to issue 6 — the `provider_connector` requirement is
the same wrong assumption about where the Terraform runs, surfacing in the API
instead of the YAML. Note that issue 6's correction does not remove this one:
even with `KubernetesDirect` build infrastructure and in-cluster identity, the
workspace form still demands a provider connector.

**UNVERIFIED.** No PAT was available, so none of this was executed against
app.harness.io; it is read from the published OpenAPI spec. Specifically
unverified: the public base path (the spec declares its server as
`http://localhost:80`; an unauthenticated probe of
`app.harness.io/gateway/iacm/api/...` returned 401, but so did a deliberately
bogus path, so that 401 proves only that the gateway requires auth); whether the
`Harness-Account` header alone suffices or `accountIdentifier` must also be a
query param; the accepted values of `provisioner` (the spec types it as a bare
string with no enum); the list of `provisioner_version` values; and whether
`PUT` accepts the same body shape as `POST`.

**Severity:** blocks workspace creation, which blocks the IaCM path entirely.
Entirely a documentation defect on the platform side.

---

## 8. DB Schema `migrationType` defaults to Liquibase and is silently ignored on update

**Symptom:** a schema created without `migrationType` comes out Liquibase.
`PUT`ting `migrationType: Flyway` afterwards returns `200` and changes
nothing.

**Cause:** the update endpoint accepts unknown and non-updatable top-level
properties without complaint — a deliberately-invalid `zzz_fake` property also
returned `200`. So the correction appears to succeed. `migrationType` is
fixed at creation time; the only fix is delete and recreate with
`migrationType: "Flyway"` in the create call.

Two adjacent API details cost time here and are worth writing down: `type` is
an enum of exactly `["Repository", "Script"]`, and the changelog field is
`changeLog`, not `changeLogScript`.

SETUP.md:174 does say **Flyway Compatible** in its UI table, so the guide is
correct — but anyone scripting this via the API gets a Liquibase schema and a
`200 OK` telling them they fixed it. Worth an explicit warning.

---

## 9. DB Instance creation requires a branch, commit, or tag

**Symptom:**

```
Branch, commitSha, or gitTag is mandatory for source type [Git]
```

**Cause:** the DB Instance's Git source needs a ref; the correct field for
this repo is `branch: "main"`. SETUP.md step 5 does not mention it. Also note
the endpoint is `.../dbschema/{id}/instance` — singular; the plural 404s.

**Fix:** add the branch field to step 5's instructions.

---

## 10. A run cancelled between apply and the wake step leaks a database permanently

**Where:** `terraform/variables.tf:57` (`last_used_timestamp`, default `""`),
`terraform/main.tf:69` (annotation set from that variable),
`terraform/reaper.tf:114-120`.

**Cause:** the reaper deliberately skips deployments with no
`harness.io/last-used` annotation:

```
No last-used annotation. Leaving it alone rather than
guessing — an unannotated database may be mid-provision.
```

That is the right instinct, and the code is well-commented about why. But
`last_used_timestamp` defaults to `""` and the pipeline never passes a value,
so a freshly applied deployment carries an *empty* annotation, which parses to
the same "leave it alone" branch. The wake step is what first writes a real
timestamp. Between `terraform apply` and the wake step there is a window —
short, but exactly the window an abort, a plan-time failure, or a cancelled
run lands in — where the database exists, is never annotated, and is therefore
immortal. The reaper is the safety net for runs that never reach teardown, and
this is precisely such a run.

`main.tf:147` puts the annotation under `lifecycle.ignore_changes`, so a
later apply will not repair it either.

**Fix:** default `last_used_timestamp` to `timestamp()`, or have stage 1 pass
`<+pipeline.startTs>`. The provision time is a truthful last-used value for a
database that has never been used, and it makes the deployment reapable from
the moment it exists. Keep the skip branch for genuinely unannotated
deployments.

**Severity:** the one issue here that costs money silently and indefinitely,
and it defeats the specific failure mode the reaper exists to cover.

---

## 11. `README.md` references `Architecture.md`, which does not exist — **fixed in this repo**

**Where:** `README.md:44` lists it in the Layout block; `README.md:105` leans
on it: "`Architecture.md` records what that exercise is expected to surface."

The file is not in the repo. That second reference is load-bearing — the
README defers its own acceptance criteria to a document that is not there, in
the same section that carefully explains why being precise about what has and
has not been run matters.

**Fix (applied):** both references replaced with this document, which is what
that section was promising. The Layout block now lists `ISSUES.md`, and the
"What has and has not been run" section — which had gone stale in the other
direction, still claiming the Terraform had never been applied — now records
what actually ran.

---

## 12. Minor: Deployment has no `strategy`, so it gets RollingUpdate

**Where:** `terraform/main.tf`

The default `RollingUpdate` on a single-replica `emptyDir` Postgres means a
spec change briefly runs two pods, and the Service can route to the new empty
one while the old one still exists. There is nothing to preserve, so this is
not a data risk — but `Recreate` matches the intent (fresh database every
run), and it removes a class of confusing intermittent connection behaviour
during rollouts.

---

## 13. `DBSchemaApply` with `migrationType: Liquibase` fails against a Flyway-typed DB Schema — **wrong diagnosis; corrected and fixed in this repo**

**This entry previously said `DBSchemaApply` "cannot run Liquibase from a
Custom-stage step group" and that "nothing in the YAML can avoid this". That is
false.** It can, it does, and the thing that avoids it is in the YAML. The
retraction is recorded here rather than deleted because the wrong conclusion was
load-bearing: it justified a `Run`-step workaround that threw away the Database
DevOps UI for half the repo's demo.

**What actually works, and is now what ships.** The Liquibase branch is a
`DBSchemaApply` step identical to the Flyway one but for `migrationType`:

```yaml
- step:
    type: DBSchemaApply
    name: Apply Schema Liquibase
    spec:
      connectorRef: <<DOCKER_CONNECTOR>>
      migrationType: Liquibase
      dbSchema: <<DB_SCHEMA_LIQUIBASE>>
      dbInstance: <<DB_INSTANCE_LIQUIBASE>>
```

Executed on app.harness.io, in exactly the Custom-stage step group this entry
claimed was impossible. The full pipeline went green — provision, Liquibase
apply, verify, destroy, `kubectl get ns dbops-ci` → `NotFound` — with the Flyway
step reporting `Skipped`. The wrapper expanded to four sub-steps, all Success:

```
Apply Schema Liquibase   DBOPS_WRAPPER
  Resource Constraint    ResourceConstraint
  Clone Codebase         DBClone
  Pre-Apply Checks       DBPreUpdate
  Apply                  DBCompositeUpdate
```

Note what is absent: no `DBCommand Import ChangeSets`. That node — the one this
entry blamed for the missing port — is not part of the Liquibase expansion at
all when the step is wired correctly.

**The difference that mattered.** The original attempt pointed
`migrationType: Liquibase` at the *Flyway* DB Schema and its instance. The
working version has a dedicated Liquibase-typed pair,
`orders_schema_liquibase` / `ephemeral_ci_liquibase`. So the probable cause of
the original failure is that the sub-step expansion is driven by the **DB
Schema's own configured migration type**, not by the step's `migrationType`
field: a Flyway-typed schema gets the five Flyway containers allocated at
`Initialize`, then the runtime takes the Liquibase branch and asks for a
container nobody reserved. "Unable to fetch port details" is the honest
downstream symptom of that mismatch, and the toggle it tells you to check is a
red herring either way.

That cause is inference from the two configurations and their outcomes; it was
not isolated by varying the schema type alone. The *fact* is the narrower
statement: **a Liquibase `DBSchemaApply` needs a DB Schema and DB Instance whose
own type is Liquibase, and given those it works.** Issue 8 is the same hazard
from the other end — `migrationType` on a DB Schema defaults to Liquibase and is
silently ignored on update — so a schema you believe you retyped may not be
retyped.

**Consequence for setup.** This is why `SETUP.md` asks for *two* schema/instance
pairs and why the pipeline has `<<DB_SCHEMA_LIQUIBASE>>` and
`<<DB_INSTANCE_LIQUIBASE>>` as separate placeholders. Reusing one pair for both
tools is the configuration that fails, and it fails with a message that points
at the step group.

Two Liquibase CLI details, kept because they still apply if you run the CLI
directly for any reason:

- `liquibase update` has no `--tag` flag. Tagging is a separate `liquibase tag`
  invocation after the update.
- Liquibase 4.x refuses an absolute `--changelog-file` path that resolves
  outside a search path, with a parser error that lists where it looked. Use
  `--search-path=.` and a path relative to it.

---

## 14. `terraform init` fails behind a TLS-inspecting proxy while everything else works — **handled in this repo**

**Symptom:**

```
Error: Failed to query available provider packages
Could not retrieve the list of available versions for provider
hashicorp/kubernetes: could not connect to registry.terraform.io: failed to
request discovery document: Get
"https://registry.terraform.io/.well-known/terraform.json": tls: failed to
verify certificate: x509: certificate signed by unknown authority
```

**Cause:** a corporate TLS-inspecting proxy. Confirm it in one command — if the
served chain is issued by your security vendor's root rather than by the real
issuer, that is the answer:

```bash
echo | openssl s_client -connect registry.terraform.io:443 \
  -servername registry.terraform.io 2>/dev/null | grep '^ *[0-9] s:'
```

The laptop and the delegate host trust that root because someone installed it
there; a build container starts from its image's CA bundle and does not.

What makes this expensive to diagnose is the selectivity. Image pulls succeed,
`GitClone` succeeds, the psql steps reach the database, and stage 2 is entirely
green. Only the Terraform steps fail, and they fail on a HashiCorp URL — so the
first hypothesis is a registry outage or a Terraform bug, not local egress.
Note also that "Reusing previous version ... from the dependency lock file"
prints just before the error: the lock file pins the version but the provider
binary still has to be downloaded, so a committed lock file does not remove the
network dependency.

**Fix on the Custom-stage path (applied):** an optional `CUSTOM_CA_PEM_B64`
pipeline variable, empty by default and a no-op when unset. Set it to a secret
expression holding `base64 < your-root-ca.pem | tr -d '\n'` and the Terraform
steps append the CA to the container trust store before `init`. Base64 rather
than raw PEM because a multi-line value has to survive expression substitution
into a shell script intact. Since issue 6's correction moved stages 1 and 3 to
IaCM, that variable and the shell block it feeds live in
`harness/custom-stages.yaml.example` rather than in the main pipeline — nothing
left in the main pipeline used them.

**Fix on the IaCM path, with caveats:** the IaCM-native route is the workspace
environment variable `PLUGIN_CA_CERT_PATH`. It is not a drop-in swap for
`CUSTOM_CA_PEM_B64`, in three ways that each matter:

- It takes a filesystem **path**, not a value. The docs describe it as "a single
  PEM file containing one or more certificates (a CA bundle), not a directory",
  and that file must **already be mounted into the container**. On Kubernetes
  build infrastructure that means the `volumes` or `podSpecOverlay` fields of
  `K8sDirectInfraYamlSpec`. There is no base64-env-var form.
- Its **documented scope is the provisioner binary download**. The failure above
  is a *provider* download from `registry.terraform.io` during `init`, which is a
  different request at a different point in the run.
- The docs do say the plugin additionally exports `SSL_CERT_FILE`,
  `CURL_CA_BUNDLE` and `SSL_CERT_DIR`, which would plausibly cover the provider
  download too, since that is how Go's TLS stack and curl find roots. **That is
  inference, not a documented guarantee, and it was not tested** — label it that
  way if you repeat it. If you are behind a TLS-inspecting proxy and adopting the
  IaCM path, assume you will have to confirm this yourself.

Harness's own error output hints at a third option ("If you are using self signed
certs, Harness allows setting them at a global level on the delegate agent"),
which is the right fix for delegate-run steps but does not reach containers in a
`KubernetesDirect` step group — which is what both paths use.

---

## 15. The provisioner needs `deployments/scale` to create Roles it never uses — **fixed in this repo**

**Symptom:** `terraform apply` creates the namespace, Secret, Service,
Deployment and CronJob, then fails on all four Roles and RoleBindings. The
database comes up healthy. The reaper exists and can never scale anything.

**Cause:** Kubernetes escalation prevention. A principal creating a Role must
already hold every permission that Role grants, or hold `escalate`. Both
`reaper.tf` and `build-access.tf` grant `deployments/scale`. The bootstrap
ClusterRole granted `deployments` but not `deployments/scale`, so it could
create the Deployment but not create a Role that mentions scaling it.

The failure mode is worse than a clean stop. A half-provisioned namespace with a
working database passes any smoke test that connects to Postgres; what is broken
is the idle reaper, which fails silently ten minutes later and leaks the
database — issue 10's symptom arriving by a different route.

**Fix (applied):** `deployments/scale` added to
`terraform/bootstrap/provisioner-rbac.yaml`, with a comment explaining that it
is there to satisfy escalation prevention rather than because anything scales a
Deployment as that identity. The general rule for that file: it must hold the
union of every permission the Terraform *grants*, not just the ones it *uses*.

---

## 16. Minor: step names cannot contain parentheses

**Symptom:**

```
Invalid yaml: $.pipeline.stages[1].stage.spec.execution.steps[0].stepGroup
.steps[4].step.name: does not match the regex pattern
^[a-zA-Z_][-0-9a-zA-Z_\s]{0,127}$
```

**Cause:** `Apply Schema (Flyway)`. The pattern allows letters, digits,
underscore, hyphen and whitespace only. Worth knowing because parenthesised
qualifiers are the obvious way to name two variants of the same step, the error
arrives at save time rather than while editing, and the JSON path is the only
clue to which of several similarly-named steps is at fault.

**Fix (applied):** `Apply Schema Flyway` / `Apply Schema Liquibase`.

---

## 17. An IACM stage that passes schema validation can still be wrong in four different ways

**Where:** `definitions.pipeline.stages.iacm` in
<https://raw.githubusercontent.com/harness/harness-schema/main/v0/pipeline.json>

**How this was found:** by reading the schema and validating candidate YAML
against it locally with `jsonschema`, while writing issue 6's fix. None of it was
observed on a Harness account, because there was no account. Everything here is
a property of the schema document, which is checkable, rather than a claim about
runtime, which is not.

**Symptom:** none. That is the problem. The stage validates and then behaves
differently from what the YAML appears to say.

**Cause:** four independent gaps, all in the same stage path.

1. **`additionalProperties: false` is set nowhere** along the IACM stage path.
   An invented key validates, both under `spec:` and at stage level. The
   specific trap this creates: `delegateSelectors` belongs to `IACMStageNode`,
   at stage level beside `spec`. Nest it under `spec:` — which is where
   everything else lives, so it is the natural guess — and the YAML is
   schema-**valid** and the selectors are simply ignored at runtime. The stage
   then runs on whatever delegate the platform picks.
2. **`IACMTerraformPluginInfo.command` is a bare `{"type": "string"}` with no
   enum.** The documented values are `init`, `plan`, `apply`, `destroy`,
   `plan-destroy`, `plan-refresh-only`, `apply-refresh-only`, `detect-drift`,
   `validate`, `fmt`, `import`, `removed` — but `plan-destory` or `initialise`
   validate cleanly and fail only at runtime. For stage 3 that means a typo
   surfaces **mid-teardown of real infrastructure**, in the step that runs with
   `when: pipelineStatus: All` — the path whose entire purpose is to run when
   something has already gone wrong.
3. **`IACMStageConfigImpl.required` is `["execution"]` and nothing else.** A
   stage with its `workspace` block dropped validates. A stage with its
   `infrastructure` block dropped validates too, and would then run somewhere
   unintended — which, given issue 6, is the one thing you most want caught.
4. **Every `oneOf` failure produces a wall of irrelevant errors.**
   `pipeline.stages[].stage` is a `oneOf` across all 13 stage node types, so one
   mistake in an IACM stage reports roughly 14 sibling-branch complaints:
   `'IACM' is not one of ['Deployment']`, `['CI']`, `['Custom']`, and so on. The
   single real error is the branch whose `schemaPath` contains
   `oneOf/0/allOf/0/then/`. Filter on that. The Harness UI may show only the
   first error, which is usually one of the useless ones.

A worked example of (4) and of why key placement is not schema-checkable:
nesting `platform:` *inside* `infrastructure.spec` is rejected, but the rejection
reads as

```
is valid under each of {'$ref': '.../HostedVmInfraYaml'}, {'$ref': '.../K8sDirectInfraYaml'} ...
```

because all five `infrastructure` variants share the same `type` enum and both
`DockerInfraSpec` and `HostedVmInfraSpec` have `required: ["platform"]`. The
error says "valid under each of", which sounds like success. The actual rule is
simpler than the error: under `KubernetesDirect` the OS lives in
`infrastructure.spec.os`, and `platform` is a schema-optional sibling of
`infrastructure`, not a child of it. This repo therefore sets `os: Linux` and
omits `platform` entirely.

**Fix:** no repo change is possible — this is upstream schema laxity. What the
repo does instead is refuse the shorthand. **"Schema-validated" must never be
reported as "will work."** The real check for key placement is server-side at
pipeline save, and the real check for `command` values is a run. Issue 6's
follow-up says "schema-validated only" for exactly this reason.

**Severity:** no immediate failure, high diagnostic cost. (2) is the sharp edge:
a one-character typo that the only automated check in reach will approve, landing
in the teardown path.

---

## 18. The OPA gate on a Terraform plan fails open if you wire it where the UI invites you to

**Where:** Harness policy sets versus the plan step's own policy configuration.

**How this was found:** by reading the IaCM governance docs while deciding
whether to enable a plan gate by default. **Not observed** — no account, no
policy set, no evaluation. The quotes below are verbatim from the docs; the
conclusion drawn from them is ours.

**Symptom:** the policy evaluates, reports pass, and the pipeline goes green
while the plan it supposedly guarded violates the policy.

**Cause:** the gate is attached at the wrong level, and the wrong level is the
one with a field for it. A plan gate must be a **policy set** with entity type
**"Terraform Plan"** and evaluation event **"After Terraform Plan"**, which
fires automatically. The docs are explicit that it will not appear in the step
UI, and that this is correct:

```
You do not attach them in the plan or apply step's policy configuration UI ...
It will not appear there. This is expected behavior.
```

So the step UI shows a policy field, the Terraform Plan policy set is absent
from it, and the obvious recovery is to attach some *other* entity type's policy
set to the step. That is the failure. In the docs' words, when the entity type is
not Terraform Plan:

```
the plan step does not pass the Terraform plan JSON as input to the policy
```

and therefore

```
the policy can pass even when the plan violates the policy rules
```

A governance gate that silently always passes is worse than no gate, because no
gate is at least honest about the coverage you have. This is the same shape as
issue 3's wedged reaper and issue 10's unannotated deployment: a control that
reports healthy while doing nothing.

**Fix:** none applied — no OPA policy is enabled in this repo by default, and
that is deliberate rather than an omission. If you add one: create a policy set,
entity type "Terraform Plan", evaluation event "After Terraform Plan"; write
Rego against `input.planned_values` and `input.resource_changes`; and verify it
through the policy set's **Evaluations** tab, which the docs say "shows the exact
input payload passed to the policy." If that payload is not the plan JSON, the
gate is not a gate. Checking the payload rather than the verdict is the whole
trick, since a fail-open gate and a correct gate produce identical green ticks.

**Severity:** no failure in this repo, because the feature is off. Severe for
anyone who turns it on by the route the UI suggests, and undetectable from the
pipeline's output.

---

## 19. The Docker/Cloud fallback's env-var credentials have three silent failure modes and a one-hour fuse

**Where:** `terraform/main.tf`'s provider block with `kube_config_path = ""`,
on the Docker or Cloud runtime path only. The primary `KubernetesDirect` path of
issue 6 does not use any of this.

**How this was found:** executed, not read. terraform 1.5.7 with provider
2.38.0, `main.tf` unchanged, full apply and destroy from the **host** — outside
the cluster — against minikube. Everything in this entry was reproduced.

**What is correct:** the three environment variable names are `KUBE_HOST`,
`KUBE_CLUSTER_CA_CERT_DATA` and `KUBE_TOKEN`. `KUBE_HOST` is a full URI with
scheme, e.g. `https://1.2.3.4:6443`. `KUBE_TOKEN` is the raw JWT.
`KUBE_CLUSTER_CA_CERT_DATA` is **raw PEM, including the
`-----BEGIN CERTIFICATE-----` lines — not base64**, despite the `_DATA` suffix
that every other Kubernetes API in existence uses to mean base64. Base64 fails
with

```
Error: Failed to configure client: unable to load root certificates: unable to
parse bytes as PEM block
```

which reads like a corrupt certificate rather than like a wrong encoding, and
sends you to re-export the cert instead of to stop encoding it.

**Trap 1, the headline: a stray kubeconfig silently wins over `KUBE_TOKEN`.**
The provider does not read `KUBECONFIG`, but it *does* read `KUBE_CONFIG_PATH`
and `KUBE_CONFIG_PATHS`. Because `kube_config_path = ""` makes `config_path`
null, that null is what activates the provider's env-var default — so a
kubeconfig found through those two variables takes over, and your carefully
configured token is ignored. Proven: with `KUBE_CONFIG_PATH` set and a
deliberately **invalid** `KUBE_TOKEN`, terraform reported

```
No changes. Your infrastructure matches the configuration.
```

with no warning of any kind. The run is green, the credentials under test were
never used, and the next environment without that kubeconfig is where you find
out. On the fallback path, `KUBE_CONFIG_PATH` and `KUBE_CONFIG_PATHS` must be
explicitly unset.

**Trap 2: `terraform plan` on an all-new configuration does not authenticate.**
It succeeds with a completely bogus token, because there is no existing state to
refresh and nothing to ask the API server. Only `apply` — or a plan that
refreshes existing state — talks to the cluster. So validating these variables
with `plan` alone is a guaranteed false pass, and `plan` is exactly what you
reach for when you want a safe check.

**Trap 3: only one of the two auth errors tells you anything.** A
valid-but-unprivileged token gives `Forbidden` and names the ServiceAccount,
which proves which identity is in use. A malformed token gives a bare
`Error: Unauthorized` with no identity at all, which is indistinguishable from a
dozen other problems. If you are debugging "is my token being used", the
Forbidden case is the one that answers the question.

**The one-hour fuse.** On Kubernetes 1.24 and later a ServiceAccount has no auto-created
token Secret, and `kubectl create token` defaults to **exactly one hour**
(measured `exp - iat` = 3600s) with no warning that it is doing so. Paste that
into a Harness secret and the pipeline works, then starts failing with
`Unauthorized` about an hour later — which looks like an RBAC or connectivity
regression, and is neither. For a stored credential, create an explicit
`kubernetes.io/service-account-token` Secret; that token has no `exp` claim.
Do **not** reach for `kubectl create token --duration=8760h`: it is silently
capped by the apiserver's `--service-account-max-token-expiration`, which merely
happened to be unset on this minikube. Managed EKS, AKS and GKE control planes
clamp it.

**And there is no ServiceAccount to use.** `terraform/bootstrap/provisioner-rbac.yaml`
as originally written binds only `harness-builds:default`, which is an
*in-cluster pod* identity. The fallback has no pod, so it has no usable token,
and a named ServiceAccount had to be created by hand to make the fallback work
at all.

**Fix (applied):** `terraform/bootstrap/provisioner-rbac.yaml` gains a clearly
marked **optional** section — a named ServiceAccount `ephemeral-db-provisioner`
in `harness-builds`, a ClusterRoleBinding of the existing ClusterRole to it, a
RoleBinding of the existing `ephemeral-db-tfstate` Role to it, and a
`kubernetes.io/service-account-token` Secret for a long-lived token. It is marked
unmistakably as needed **only** for the Docker/Cloud fallback. The existing
`harness-builds:default` bindings are untouched, because they are what the proven
primary path uses.

**One security consequence worth saying out loud.** On the fallback path
`build-access.tf` grants nothing to the actual caller, because the caller is not
a build pod in the cluster. Stage 2's wake step then falls back on the ClusterRole
`ephemeral-db-provisioner`, which already carries `deployments` get/list/watch/patch
and `deployments/scale` get/update/patch **cluster-wide**. That is a materially
broader grant than the in-cluster path needs, and it is the kind of thing that
gets granted once for a fallback and never revisited.

**Severity:** not a blocker, since this is the secondary path. But Trap 1 and
Trap 2 both produce green runs from broken credentials, and the token fuse
produces a failure an hour after the change that caused it.

---

## 20. The example backend gives every consumer on a cluster the same state object

**Where:** `terraform/backend-kubernetes.tf.example`

**How this was found:** observed. The state Secret was inspected before and
after a run.

**Symptom:** none until two things share a cluster. Then one pipeline's `apply`
overwrites the other's state, and the loser's `destroy` plans against the
winner's resources.

**Cause:** the example hardcodes `secret_suffix = "ephemeral-db"`, so the state
lives at `secret/tfstate-default-ephemeral-db` in `harness-builds` for
*everyone*. It was observed at `serial = 18` before a run and `19` after, which
is the state object doing its job — for one consumer. Two pipelines, two
`DB_NAMESPACE` values, or two branches of this repo against the same cluster all
write to that one Secret. The `Lease` the backend takes serializes *concurrent*
access; it does nothing to separate *unrelated* states, so the collision is
silent rather than a lock error.

**Fix:** `secret_suffix` cannot be a variable inside a backend block, so the fix
has to move to init time: `-backend-config=secret_suffix=<something-unique>`,
keyed off the namespace or the pipeline identifier. The example file should say
so rather than look like a complete configuration.

**Scope:** Custom-stage fallback only. On the primary IaCM path of issue 6 the
platform owns state, one state per workspace, and this cannot happen.

**Severity:** silent cross-contamination of Terraform state, which is near the
top of the list of things you do not want to be silent. Low likelihood for a
single-consumer demo, which is exactly why it would ship.

---

## 21. arm64 build infrastructure is undocumented in both directions

**How this was found:** by reading the docs and the published image tags. **Not
a Harness statement either way** — there is no answer on the page to quote.

**Symptom:** unknown. That is the finding.

**Cause:** the IaCM delegate doc says "Be sure to set your delegate tags to
Linux / Amd64" and shows `arch: Amd64`. The strings `arm64` and `aarch64` appear
nowhere on that page, and `plugin-images.md` says custom-image binaries "need to
be suitable for the amd64 architecture". So the documented support matrix is
amd64 and nothing else — but it never says arm64 is unsupported, it just never
mentions it.

Against that, all of it our own observation rather than a Harness commitment:
the pipeline schema's `arch` enum is `[Amd64, Arm64]`;
`plugins/harness_terraform`, `plugins/harness_terraform_vm`,
`harness/ci-addon`, `harness/ci-lite-engine` and `harness/drone-git` all publish
`linux/arm64`; and `terraform_1.5.7_linux_arm64.zip` exists. The verification in
issue 6 ran on minikube linux/arm64 throughout.

**Fix:** none available. The honest framing, which is what the repo says: it
works today, it is off the documented support matrix, and therefore breakage is
not escalatable as a bug. If you are standing this up on arm64 for anything that
matters, that is the risk you are accepting.

**Severity:** no observed failure. A support risk, recorded so that nobody reads
"it worked on arm64" as "arm64 is supported".

---

## 22. Minor: an `IACMApproval` step holds the build pod open and widens issue 10's leak window

**How this was found:** docs, while deciding whether to enable a plan approval
by default. **Not observed.**

**Cause:** an approval step in an IaCM stage does not release the compute. Per
the docs, "the underlying machine running the pipeline remains active until the
approval is resolved. This means it will continue consuming compute resources",
and "The approval plan step has a timeout of up to 60 minutes ... Upon timeout,
the pipeline fails."

Both halves hurt here. A gate between plan and apply in stage 1 is sitting a
human-length pause inside the exact window issue 10 describes — between
`terraform apply` and the wake step that writes the first real
`harness.io/last-used` annotation — and a pipeline that fails or is cancelled in
that window leaves a database the reaper refuses to touch. The 60-minute ceiling
means an unattended approval does not just stall, it fails the pipeline, which is
the cancelled-run case rather than a clean one.

**Fix:** no approval step is enabled in this repo, deliberately. If you add one,
put it where a pause is cheap — a gate on *destroy* rather than on provision, or
a gate before provision rather than between plan and apply — and fix issue 10
first, because `last_used_timestamp` defaulting to `timestamp()` makes an
abandoned database reapable and removes most of the cost of a long pause.

**Severity:** minor as written, because the feature is off. It is here because
"add a plan approval" is the first thing anyone does with a plan artifact, and
the interaction with issue 10 is not obvious from either entry alone.

---

## 23. The repo's headline acceptance check is impossible without `allowStageExecutions: true` — **fixed in this repo**

**Symptom:** running one stage on its own is simply not offered. The UI shows no
stage picker, and the API refuses outright:

```
POST /pipeline/api/pipeline/execute/{id}/stages
HTTP 400 — Stage executions are not allowed for pipeline [...]
```

**Cause:** selective stage execution is opt-in per pipeline, via a single
top-level key, and nothing in the authoring experience tells you it is missing —
the absence reads as "this version of Harness cannot do that".

**Why it is not cosmetic here.** The headline acceptance check for this repo is
"run stage 1 alone, then stage 3 alone, and confirm the namespace is gone". That
*is* a selective stage execution. Without the key there is no way to perform the
one check that distinguishes a real destroy from a green tick over empty state.

**Fix (applied):** `allowStageExecutions: true` on the pipeline, with a comment
recording the 400 above. Reproduced on a pipeline identical to the shipped one
but for that key.

---

## 24. `branch: <+input>` on a `GitClone` step kills the stage before any step runs

**Symptom:** the Custom stage fails at `Initialize`, before `GitClone` is
reached, with:

```
[Environment variable DRONE_COMMIT_BRANCH can't be empty or null]
```

Reproduced three times: once with the input left unset, once with the branch
supplied at trigger time, and once with the input-set template fetched from
`POST /pipeline/api/inputSets/template` and filled in verbatim. Supplying the
value does not help.

**Cause:** `InitializeContainer` builds the environment for the *whole* step
group before any step executes, and it does so from the unresolved YAML. A
`GitClone` step's `branch` becomes `DRONE_COMMIT_BRANCH` at that moment, and a
runtime input has not been substituted yet. The failure is therefore structural,
not a missing value — which is why filling the template in correctly reproduces
it exactly.

The error names a Drone variable that appears nowhere in this repo, so the
natural reading is "something is wrong with the clone step". The clone step never
ran.

**Fix (applied):** `branch` is a setup-time placeholder, `<<REPO_BRANCH>>`,
substituted when you fill in the pipeline. This matches the only pipeline shape
with a long green history behind it, which hardcodes `branch: main`. `SETUP.md`
now says in bold not to turn any placeholder into `<+input>`, and says which one
runtime input *does* work — `MIGRATION_TOOL`, because it is a pipeline variable
consumed by a `when` condition rather than by a container's environment.

---

## 25. `Initialize` validates `DBSchemaApply` references for steps it is about to skip

**Symptom:** a run with `MIGRATION_TOOL` set to `Flyway` fails in the Flyway
path with:

```
Failed to create inputs for plugin for reason - HTTP Error Status
(404 - Resource Not Found) received. instance with id [ephemeral_ci]
schema [orders_schema_liquibase] does not exist
```

Nothing in the Flyway path references `orders_schema_liquibase`. The step that
does is the Liquibase step, whose `when` condition is false and which the same
run correctly reports as `Skipped`.

**Cause:** the same `Initialize` behaviour as issue 24, in a second guise. The
container environment for the whole step group is built up front from the YAML,
so `DBSchemaApply`'s schema and instance references are resolved against the
Database DevOps API for *every* declared step, including the ones about to be
skipped. `when` is evaluated later and cannot save you.

**Consequence, and it is the practical one:** a wrong `dbSchema`/`dbInstance`
pair on the branch you are not using still fails the branch you are. So both
pairs must exist and be correct before either tool can run, and you cannot
stage the setup one tool at a time. This is also why the two placeholders in
`SETUP.md` are not optional even if you only ever intend to run Flyway.

Worth knowing when reading the message: it names schema and instance from
*different* steps if you have mixed them up, because the schema is read from one
field and the instance from another with no cross-check.

---

## 26. Pipeline-variable values sent to the execute API are accepted and silently ignored

**Symptom:** `POST /pipeline/api/pipeline/execute/{id}` with
`runtimeInputYaml` setting a pipeline variable returns HTTP 200 and
`status: SUCCESS`, and the execution runs with the variable's **default**.

Observed with `MIGRATION_TOOL`, declared as
`<+input>.default(Flyway).allowedValues(Flyway,Liquibase)`. Two runs sent
`Liquibase`; both resolved their `when` conditions as `Flyway == "Liquibase"`
(false) and `Flyway == "Flyway"` (true) and ran Flyway. The literal `Flyway` in
those resolved conditions is the variable's default, not the value sent.

**How it was isolated**, because "accepted and ignored" is easy to assert and
hard to prove: a third run sent `value: Bogus`. `allowedValues(Flyway,Liquibase)`
must reject that if the value is read at all. It returned HTTP 200 / SUCCESS and
then executed the Flyway branch. A value that is neither rejected nor used is
not being read.

**Severity for a reader of this repo: low.** The UI's run dialog sets the
variable correctly; this is an API-shape problem, and the likely cause is that
the body wants the variable under a different key or wants an input set
reference rather than inline YAML. It is recorded because it wastes an entire
debugging session: the API reports success, the pipeline goes green, and the
only evidence that anything was ignored is a `Skipped` step you expected to run.

**Workaround used to verify the Liquibase branch:** pin the value in the
pipeline YAML (`value: Liquibase`) and trigger with no inputs at all. Blunt, but
it removes the variable from the question entirely.

---

## 27. The Database DevOps instance API path is `instance`, singular, and nothing documents it

**Symptom:** every plausible spelling 404s —
`/dbschema/{schema}/dbinstance`, `/dbinstances`, `/db-instances`,
`/instances`.

**Cause:** the working path is

```
GET /gateway/v1/orgs/{org}/projects/{proj}/dbschema/{schema}/instance[/{id}]
```

Singular `instance`, and `dbschema` for the parent rather than `dbschemas`. The
inconsistency between the two segments is the trap.

**How to tell a wrong path from a wrong body**, which is the transferable part:
the gateway answers an unrouted path with

```json
{"message":"no matching operation was found"}
```

while a routed path with a bad body gives a field-level validation error. Probing
segments with `POST` and sorting responses by which of those two you get locates
a path in a few requests instead of a few dozen.

This matters because issue 25 makes the instance identifiers a hard prerequisite
for any run, and the only way to discover the ones that already exist is to list
them.

---

## 28. The IaCM workspace outputs endpoint could not be found — **unresolved**

**Symptom:** `/resources` works and returns the 10 provisioned resources.
Nothing returns Terraform **outputs**. Tried, all 404:

```
/workspaces/{ws}/outputs        /workspaces/{ws}/output
/workspaces/{ws}/terraform-outputs
/workspaces/{ws}/state          /workspaces/{ws}/state-outputs
/workspaces/{ws}/latest-state
```

**Consequence:** the acceptance check "the Resources tab shows `jdbc_url` from
`outputs.tf`" is **unconfirmed**. The Resources tab itself is confirmed — 10
resources, listed — and `outputs.tf` is confirmed to produce a working
`jdbc_url`, because `psql` connected over that exact value on the direct-minikube
tier. What is not confirmed is that IaCM surfaces it.

This is listed as an issue rather than quietly omitted because it is the one
acceptance check in the brief that has no evidence behind it, and a reader
deciding whether to depend on IaCM outputs should know that.

---

## What was verified working

For balance, and because the README asked for exactly this. Everything in this
list was observed. Unless a bullet says otherwise it was observed on
app.harness.io, with stages 1 and 3 as Custom stages:

- `GitClone` in a Custom-stage containerized step group: **works** (subject to
  issue 4's working directory).
- `DBSchemaApply` with `baselineOnMigrate: "true"`: **works**, and the setting
  is load-bearing as documented —
  `Successfully baselined schema with version: 1`, then
  `Migrating schema "public" to version "2 - add order status"`.
- Green run: all steps Success,
  `PASS: all 6 checks passed against 4 seeded orders`.
- Red run: `ERROR: column "status" of relation "orders" contains null values`,
  `Changes successfully rolled back`. The demo holds.
- Reaper, scale-to-zero branch: `Idle for 211814441s, threshold 3600s.` →
  `Scaling ephemeral-db to zero.`, replicas 1 → 0.
- Reaper, skip branch: no annotation → left alone, replicas stayed 1. Note
  that `alpine/k8s` ships BusyBox `date` with no GNU `-d`, so this run
  exercised the second half of the `date` fallback at `reaper.tf:124-126` —
  previously untested, and correct.
- Wake-from-reaped: scaled the database to 0, ran the pipeline,
  `Reaper had scaled this to zero. Waking it.` →
  `deployment.apps/ephemeral-db scaled` →
  `deployment "ephemeral-db" successfully rolled out`. Green through verify.
- `build-access.tf` after the fix in issue 5: the cross-namespace RoleBinding
  grants exactly what the wake step needs and nothing more.
- Terraform in a build pod with no kubeconfig and no cloud credentials, state in
  a Kubernetes Secret: **works**. Provision from an empty cluster in 94s,
  destroy in 52s, and the destroy really does destroy — `dbops-ci` is
  `NotFound` afterwards, which is the check that distinguishes a working
  teardown from a green tick over empty state.
- Liquibase applying the *same* `sql/migrations` files through
  `sql/db.changelog-master.xml`: **works**, verified in three directions before
  it ever reached Harness. Against a pre-baselined and seeded database,
  `1-baseline` reports `MARK_RAN` on its `tableExists` precondition and
  `2-add-order-status` reports `EXECUTED`; against an empty database both
  report `EXECUTED`; against the broken V2 it fails with the identical
  `column "status" of relation "orders" contains null values`. So the
  broken-migration demo is tool-independent, which was the point.
- `when` gating on a pipeline variable across two alternative steps: **works**,
  including that the unselected step reports `Skipped` rather than being
  silently absent from the graph.
- **The identity an IaCM Kubernetes build pod would run as: works.** Run
  directly on minikube, not through Harness — terraform 1.5.7 in a pod in
  `harness-builds` as ServiceAccount `default`, no kubeconfig, no cloud
  credentials, `main.tf` unchanged. Two applies and two destroys of 10 resources
  each, **40 resource operations with zero `Forbidden`**, so the bootstrap RBAC
  is sufficient as written for this path. The projected token was present at
  `/var/run/secrets/kubernetes.io/serviceaccount/` with
  `KUBERNETES_SERVICE_HOST=10.96.0.1`; the provider resolved to
  `hashicorp/kubernetes` v2.38.0 from the committed lock file; `psql` connected
  over the exact `jdbc_url` output and reported
  `PostgreSQL 16.4 (Debian 16.4-1.pgdg120+2) on aarch64-unknown-linux-gnu`;
  `harness.io/last-used` carried a real `timestamp()` value; and a destroy from a
  separate pod through shared state left `dbops-ci-v1` at `NotFound`. What this
  does **not** show is the IACM stages running: they have never been executed on
  a Harness account, no workspace was created, and the Resources tab was never
  seen. See issue 6.

The design is sound and the parts that were hardest to get right — the stable
DNS name, `baselineOnMigrate`, the seed-derived assertions, the reaper's
refusal to guess — are all correct. What failed was everything that had never
been submitted to an API: five of the six container steps' registry, one
plan-time schema error, three missing RBAC verbs, a working directory, a
retired image, and a step name.

The last item on that list used to read "a provisioning runtime that cannot
reach the cluster it provisions", and that was the one entry here that was wrong
rather than merely unflattering. The runtime could reach the cluster the whole
time, through `infrastructure: type: KubernetesDirect` — a field nobody looked
at, because the error message named a different one and named it correctly. So
the real last item is a reading failure, and a well-earned one: an accurate error
about `runtime.type` was taken as evidence about a capability that `runtime.type`
does not control, and a documented sentence that said otherwise was discounted
because the page's examples did not show it. Everything else in this document was
found by submitting something and watching it fail. This one was found by
reading the schema, which is the cheaper check, and it was available from the
start.
