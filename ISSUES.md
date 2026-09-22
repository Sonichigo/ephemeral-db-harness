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
build pods in a separate **unprivileged** namespace `harness-builds`. Everything
executed on app.harness.io against that cluster.

All three stages now run green on the platform, from an empty cluster to a
destroyed namespace, on both migration tools:

| Tool | Provision | Migrate | Destroy | Total |
|---|---|---|---|---|
| Flyway | 102s | 146s | 81s | 5m34s |
| Liquibase | 94s | 87s | 52s | 3m56s |

Single-node minikube on a laptop, so treat these as an upper bound on a real
cluster rather than a benchmark.

The Liquibase run started from nothing — no namespace, empty Terraform state —
and ended with the namespace gone. In each run the other tool's step reports
`Skipped`, so the `when` gating on `MIGRATION_TOOL` is doing what it claims.

One asymmetry visible in the execution list and worth knowing before you pick a
tool: the Flyway run shows a schema-to-instance update summary in Harness and
the Liquibase run shows none, because the Liquibase branch bypasses
`DBSchemaApply`. That is issue 13's cost, made concrete.

The core claim of the repo holds: the same `ALTER TABLE` succeeds on an empty
database and fails with
`column "status" of relation "orders" contains null values` on the seeded one,
and `baselineOnMigrate` is load-bearing exactly as documented. The issues below
are everything between "the idea is right" and "the pipeline runs".

Ordering: blockers first (the pipeline cannot start or cannot pass), then
documentation that actively misleads, then design gaps. Entries marked
**fixed in this repo** or **applied** are done; the rest are documentation
corrections or upstream platform behaviour.

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

## 6. IaCM cannot run this Terraform against a private cluster at all — **fixed in this repo**

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

So for a private cluster with a Kubernetes delegate, neither value works. This
is not a misconfiguration in the repo; it is a gap between what IaCM offers and
what this Terraform needs.

**Fix (applied):** stages 1 and 3 are now Custom stages that run
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

The IaCM stages are preserved verbatim in `harness/iacm-stages.yaml.example`.
They are the better choice when the cluster endpoint is reachable from wherever
the runtime executes — you get the Resources tab, drift detection, cost
estimation and a plan artifact to gate on. The example file states the
constraint at the top so nobody adopts it and rediscovers this.

**Severity as authored:** the entire provision/destroy half of the pipeline.
Now verified end to end — see "What was verified working".

---

## 7. IaCM workspace creation requires `provider_connector`

**Symptom:** `POST .../iacm/api/.../workspaces` returns 400 until
`provider_connector` is supplied. Separately, `terraform_variables` must be a
map — passing an array (the shape that reads naturally for a variable *list*)
is also a 400.

**Cause:** IaCM requires a provider connector per workspace regardless of
whether the Terraform needs cloud credentials. SETUP.md:85-87 says "there are
no cloud credentials to supply, because the provider uses the delegate's
in-cluster identity" — true of the Terraform, false of the workspace form.
The API will not create the workspace without it.

**Fix:** document the connector as a prerequisite in step 2 and say which
connector to use (the Kubernetes connector for the target cluster). Related to
issue 6: this is the same wrong assumption about where the Terraform runs,
surfacing in the API instead of the YAML.

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

## 13. `DBSchemaApply` cannot run Liquibase from a Custom-stage step group

**Symptom:** with `migrationType: Liquibase`, the step fails immediately:

```
Invalid request: Unable to fetch port details. Please verify pipeline yaml and
check if 'Enable container based execution' toggle is on for step group.
```

The message is wrong in a way that costs real time. The step group *is*
container-based — the identical step group runs five other container steps
green, and the same step with `migrationType: Flyway` runs green in the same
step group.

**Cause:** a plan/runtime mismatch inside the step's own expansion. The
Flyway path expands to five containers, which `Initialize` allocates:
`dbops-clone`, `info`, `migrate-sql`, `repair`, `db_apply_schema`. The
Liquibase path allocates four — `dbops-clone`, `compositeupdate`, `preupdate`,
`postupdate` — and then at runtime asks for a fifth sub-step,
`DBCommand Import ChangeSets`, that Initialize never allocated a container for.
No port, hence the message. Confirmed by reading the execution graph: the
failing node is `Failed DBCommand Import ChangeSets` and it has no
corresponding entry in Initialize's container list.

Ruled out: `when`-condition gating (fails identically ungated), the `tag:`
field from issue 1 (fails with it removed), and a missing changeset-import
step of our own — nine plausible import endpoints all return 404, so there is
no API to pre-import changesets. `DBSchemaApply` is also absent from the CI
stage's step enum, so a Custom stage step group is the only place it can be
declared. Nothing in the YAML can avoid this.

**Fix (applied):** the Liquibase branch runs `liquibase/liquibase:4.29`
directly in a `Run` step — `update`, then `tag <+pipeline.executionId>`. It
reads the same `sql/db.changelog-master.xml` and applies the same SQL files, so
both branches are genuinely equivalent and the broken-migration demo fails the
same way under either. What is lost is the Database DevOps UI for that branch:
no changeset table, no per-instance history. Worth reporting upstream rather
than working around permanently.

Two Liquibase CLI details that cost time and are not obvious:

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

**Fix (applied):** an optional `CUSTOM_CA_PEM_B64` pipeline variable, empty by
default and a no-op when unset. Set it to a secret expression holding
`base64 < your-root-ca.pem | tr -d '\n'` and the Terraform steps append the CA
to the container trust store before `init`. Base64 rather than raw PEM because a
multi-line value has to survive expression substitution into a shell script
intact.

Harness's own error output hints at this ("If you are using self signed certs,
Harness allows setting them at a global level on the delegate agent"), which is
the right fix for delegate-run steps but does not reach containers in a
`KubernetesDirect` step group.

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

## What was verified working

For balance, and because the README asked for exactly this:

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

The design is sound and the parts that were hardest to get right — the stable
DNS name, `baselineOnMigrate`, the seed-derived assertions, the reaper's
refusal to guess — are all correct. What failed was everything that had never
been submitted to an API: five of the six container steps' registry, one
plan-time schema error, three missing RBAC verbs, a working directory, a
retired image, a step name, and a provisioning runtime that cannot reach the
cluster it provisions.
