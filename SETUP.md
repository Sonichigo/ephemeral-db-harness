# Setup Guide

Order matters here. The DB DevOps objects must exist before the pipeline
references them, and the JDBC connector must match the Terraform output
exactly or stage 2 will fail with a connection error that looks like a
network problem but isn't.

Estimated time: about 45 minutes the first time.

---

## Prerequisites

You bring the cluster. Everything past that is cloud agnostic — the Terraform
talks to the Kubernetes API and nothing else, so AKS, EKS, GKE, and
self-managed clusters are all the same from here.

- **Harness account with Database DevOps enabled.** DB DevOps sits behind a
  feature flag (`DBOPS_ENABLED`); if the module isn't in the picker, that's why.
  IaCM is *optional* — the pipeline as shipped provisions with a Custom stage,
  for the reason in `ISSUES.md` issue 6. You only need IaCM if you switch to
  `harness/iacm-stages.yaml.example`.
- **A Harness Delegate running inside the target cluster.** Non-negotiable:
  the delegate is what gives DB DevOps network access to a database that only
  exists at an in-cluster DNS name.
- **A Git connector** pointing at the repo holding `sql/` and `terraform/`.
- **A Docker registry connector.** Every container step needs one, and it must
  not be `account.harnessImage` — that connector rewrites image names to
  Harness's own registry and every pod lands in `ImagePullBackOff` with
  `manifest unknown`. `ISSUES.md` issue 2 has the detail.
- **A Kubernetes connector** for the target cluster, used by the step group
  build infrastructure in all three stages.
- **The bootstrap RBAC applied once, by a cluster admin:**

  ```bash
  kubectl apply -f terraform/bootstrap/provisioner-rbac.yaml
  ```

  This is the "you bring the cluster and the permissions" part made explicit.
  It grants the build ServiceAccount what the Terraform needs and nothing more.
  Skip it and stage 1 fails `Forbidden` on the first namespace it tries to
  create. Edit the namespaces in that file if yours differ — the subject
  namespace has to match `<<HARNESS_BUILD_NAMESPACE>>` and `build_namespace`.

- **The namespace your build pods run as, and it should not be the delegate's.**
  Stage 2 runs `kubectl` against the database's namespace from a build pod, which
  runs as the build namespace's service account — not the delegate's. Terraform
  grants that account the access it needs (`terraform/build-access.tf`), but it
  has to be told which account to grant it to: `build_namespace` and
  `build_service_account`. Get these wrong and the wake step fails with
  `deployments.apps is forbidden`.

  Do not point `build_namespace` at the delegate's own namespace to make this
  easier. Delegates are usually installed with a cluster-admin binding, so
  `build-access.tf` becomes a no-op that appears to work — and you find out it
  never granted anything the first time you run somewhere properly scoped.

- **If your egress goes through a TLS-inspecting proxy** — the kind of corporate
  MITM appliance that re-signs every HTTPS connection — set the
  `CUSTOM_CA_PEM_B64` pipeline variable.
  Everything else will work and `terraform init` alone will fail on
  `x509: certificate signed by unknown authority`. `ISSUES.md` issue 14 explains
  why only that step notices.

## Step 1 — Decide the stable endpoint first

Do this before touching anything else, because every later step hardcodes it.

The database is disposable. The *address* is not. Pick it now:

```
ephemeral-db.dbops-ci.svc.cluster.local:5432/app_test
```

That maps to `service_name = "ephemeral-db"` and `namespace = "dbops-ci"` in
`terraform/variables.tf`. If you change either, change the JDBC connector in
step 3 to match.

**Why this matters:** DB Instances in Harness require *fixed* connectors —
you cannot pass a connector as a pipeline expression. That's deliberate:
drift detection resolves the schema, instance, and connector outside of
pipeline execution, so it needs them to be static.

What that rules out is *swapping the reference* per run. It does not rule out
the endpoint behind the reference changing, and there are two ways to live
with it:

1. **Keep the address constant** — what this guide does, and why the DNS name
   is decided first. A hand-created connector pinned to a Service name stays
   valid forever, and the workspace needs no Harness credentials.
2. **Keep the connector identifier constant and let Terraform own its URL** —
   see `terraform/jdbc-connector.tf.example` and the alternative in step 3.
   Necessary when the endpoint is generated rather than chosen, as with Cloud
   SQL, RDS, or MongoDB Atlas.

Option 1 is simpler and sufficient here, because a Kubernetes Service gives
you a constant address at no cost. Do not carry away the impression that
Terraform outputs and DB DevOps are fundamentally incompatible; they are not.

---

## Step 2 — Nothing to do, unless you want IaCM

Stages 1 and 3 run Terraform in a build pod inside the target cluster, using the
pod's own ServiceAccount token. There is no workspace to create, no provider
connector, and no state to configure beyond the backend the stage copies into
place itself. The only prerequisite is the bootstrap RBAC above.

That is a correction, not a simplification: IaCM's `runtime.type` accepts only
`Cloud` (outside your network) and `Docker` (a container on the delegate host,
which a Kubernetes delegate cannot provide), so neither can reach a private
cluster the way this Terraform expects. `ISSUES.md` issue 6 has the full
reasoning and the exact error.

**If your cluster endpoint is reachable** from wherever the IaCM runtime
executes, `harness/iacm-stages.yaml.example` drops in over stages 1 and 3 and is
worth using — you get the Resources tab, drift detection and cost estimation.
For that you also need:

1. IaCM module → **Workspaces** → **New Workspace**
2. Name: `ephemeral-db-ci`
3. Provisioner: **OpenTofu** (or Terraform ≤ 1.5.x — 1.6.0+ is BSL-licensed
   and not supported)
4. Repository: your Git connector, path `terraform/`
5. A **provider connector**. The workspace API returns 400 without one even
   though this Terraform needs no cloud credentials — use the Kubernetes
   connector for the target cluster. (`terraform_variables` must also be a map,
   not an array, if you are creating the workspace over the API.)
6. Workspace variables from `terraform/variables.tf`. Only `db_password` needs
   to be marked **secret**.

   Set `build_namespace` and `build_service_account` to match where your
   pipeline's build pods run. `build_namespace` must equal
   `<<HARNESS_BUILD_NAMESPACE>>` from step 6. Leave `build_service_account` as
   `default` unless your Kubernetes connector specifies one for the step group.

   Set `kube_config_path` and mount a kubeconfig. Under IaCM this is the normal
   path, not the exception — a `Docker` runtime is a container on a host and gets
   no ServiceAccount token, and a `Cloud` runtime has no in-cluster identity at
   all. The variable's own comment says it is for delegates outside the cluster;
   with IaCM, treat it as required.

Note the workspace ID. It goes into `<<IACM_WORKSPACE_ID>>` in the example file,
in **both** the provision and destroy stages.

**Verify before moving on:** run just stage 1, then just stage 3. What you are
checking is not that stage 1 goes green — it is that stage 3 *destroys
something*. `kubectl get ns dbops-ci` should come back `NotFound`. A destroy
that cannot see the provision's state prints "no changes" and goes green over a
database that is still running.

---

## Step 3 — Create the JDBC connector

DB DevOps module → **Connectors** → **New JDBC Connector**

| Field | Value |
|---|---|
| Name | `ephemeral-db-jdbc` |
| JDBC URL | `jdbc:postgresql://ephemeral-db.dbops-ci.svc.cluster.local:5432/app_test` |
| Username | `ci` |
| Password | secret ref → `ephemeral_db_password` |
| Delegate | the in-cluster delegate |

**The test connection will fail right now.** That is expected and correct —
nothing is provisioned yet. Save it anyway. To test it properly, run stage 1
alone, then come back and hit Test Connection while the database is up.

### On the password

The password is a fixed Harness secret, not generated per run. Create it
first:

Account Settings → Secrets → **New Secret** → **Text**
- Name: `ephemeral_db_password`
- Value: anything reasonable

Then pass it into IaCM as a **secret** workspace variable named `db_password`.

This is a deliberate choice rather than a shortcut. The JDBC connector needs
a fixed credential behind it, and the database sits on an internal ClusterIP
with no ingress for a few minutes at a time. Generating a fresh password per
run would mean pushing it into the Harness secret mid-apply, which creates an
ordering dependency between stages: if the secret update fails, stage 2
authenticates with a stale password and reports what looks like a network
error. The threat model here does not justify that failure mode.

### Alternative: let IaCM create the connector

Everything in this step is manual because the connector only has to be made
once. If you would rather not click it, `terraform/jdbc-connector.tf.example`
provisions the same connector with `harness_platform_connector_jdbc`. Drop the
`.example` suffix, add the `harness` provider to `required_providers` in
`main.tf`, and supply the account, org, project, and a Harness API key as
workspace variables — the API key marked **secret**.

Two things to know before you do:

- The connector becomes Terraform-managed, so stage 3's `destroy` deletes it
  along with the database. Between runs the DB Instance then references a
  connector that does not exist. Keep the connector in a separate, long-lived
  workspace if that matters to you.
- The identifier is the contract with the DB Instance. `url` may change on
  every apply; `identifier` must not change at all.

This is the pattern to reach for when the database's endpoint is generated for
you rather than chosen by you. It buys nothing here, where the Service name is
already constant, beyond removing this manual step.

---

## Step 4 — Create the DB Schema

DB DevOps → **DB Schemas** → **Add New DB Schema**

| Field | Value |
|---|---|
| Name | `orders_schema` |
| Migration Type | **Flyway Compatible** |
| Connector | your Git connector |
| Path to Schema File | `sql/migrations` |

Harness reads versioned files (`V1__`, `V2__`) from that directory.

**Set the migration type when you create it.** It is fixed at creation and
cannot be changed afterwards. If you create schemas over the API, note that
omitting `migrationType` silently defaults to Liquibase, and `PUT`ting
`migrationType: Flyway` later returns `200` and changes nothing — the update
endpoint accepts non-updatable properties without complaint, so the correction
looks like it worked. Delete and recreate. `ISSUES.md` issue 8.

**For Liquibase**, create a second schema pointing at `sql` (not
`sql/migrations`) with Migration Type **Liquibase** and the changelog
`db.changelog-master.xml`. The changelog references the same migration files, so
both tools apply byte-identical SQL. Note that the shipped pipeline's Liquibase
branch runs the Liquibase CLI rather than `DBSchemaApply`, for the platform bug
in `ISSUES.md` issue 13 — so a Liquibase schema and instance are only needed if
you are trying `DBSchemaApply` yourself.

---

## Step 5 — Create the DB Instance

Inside the schema you just made → **Add New DB Instance**

| Field | Value |
|---|---|
| Name | `ephemeral_ci` |
| Connector | `ephemeral-db-jdbc` from step 3 |
| Context | `ci` |
| Branch | the branch holding your `sql/` directory, e.g. `main` |

The `ci` context tag keeps these runs from polluting the migration state
dashboard for your real environments.

The branch is not optional even though the schema already has one: instance
creation requires a branch, commit, or tag of its own and returns 400 without
one.

---

## Step 6 — Wire up the pipeline

Take `harness/pipeline-ephemeral-db-ci.yaml` and replace:

| Placeholder | Value |
|---|---|
| `<<PROJECT_ID>>` / `<<ORG_ID>>` | your project and org |
| `<<GIT_CONNECTOR>>` | Git connector ref |
| `<<REPO_NAME>>` | repo the `GitClone` step checks out, e.g. `ephemeral-db-harness` |
| `<<K8S_CONNECTOR>>` | Kubernetes connector ref, used by all three step groups |
| `<<DOCKER_CONNECTOR>>` | Docker registry connector ref. **Not** `account.harnessImage` |
| `<<HARNESS_BUILD_NAMESPACE>>` | namespace for build pods, e.g. `harness-builds`. Must match `build_namespace` and the bootstrap RBAC subject. Not your delegate's namespace |
| `<<DB_HOST>>` | `ephemeral-db.dbops-ci.svc.cluster.local` |
| `<<DB_NAMESPACE>>` | `dbops-ci` |
| `<<DB_SCHEMA_FLYWAY>>` | `orders_schema` from step 4 |
| `<<DB_INSTANCE_FLYWAY>>` | `ephemeral_ci` from step 5 |

Two pipeline variables, both at the top of the file:

- `MIGRATION_TOOL` — `Flyway` or `Liquibase`, defaults to `Flyway`. Selects
  which of the two apply steps runs; the other reports `Skipped`.
- `CUSTOM_CA_PEM_B64` — leave empty unless you are behind a TLS-inspecting
  proxy. See the prerequisites.

If you are using `harness/iacm-stages.yaml.example` instead, it also needs
`<<IACM_WORKSPACE_ID>>` and `<<DELEGATE_SELECTOR>>`.

Paste into the pipeline YAML editor and save.

One save-time trap worth knowing: step names allow letters, digits, underscore,
hyphen and whitespace only. `Apply Schema (Flyway)` is rejected against
`^[a-zA-Z_][-0-9a-zA-Z_\s]{0,127}$`, and the error identifies the step by JSON
path rather than by name.

---

## Step 7 — Run it, then break it

**Run 1 — it should pass.** Watch the three stages: provision, migrate and
verify, destroy. Total runtime should land around three to five minutes,
most of it Terraform.

**Run 2 — make it fail.** This is the run worth demoing:

```bash
cp sql/broken/V2__add_order_status_BROKEN.sql \
   sql/migrations/V2__add_order_status.sql
git commit -am "add status column" && git push
```

The migration is a plain `ADD COLUMN status TEXT NOT NULL`. Against an empty
database it applies cleanly. Against the seeded database this pipeline
provisions, it fails:

```
ERROR: column "status" of relation "orders" contains null values
```

Stage 2 goes red, stage 3 still runs and tears everything down.

That contrast is the whole talk. Same SQL, two databases, opposite results —
and the one that told the truth is the one that had rows in it.

---

## Troubleshooting

**"Connection refused" in stage 2, or DBSchemaApply cannot reach the host**
The step group isn't running in the cluster, or the DNS name doesn't match
the Service. Confirm `stepGroupInfra.type` is `KubernetesDirect` and that
`<<DB_HOST>>` matches the Terraform output exactly.

**DB Instance won't accept an expression for the connector**
It won't, by design. Step 1 covers the two ways to work with that.

**`deployments.apps "ephemeral-db" is forbidden` in the wake step**
Read the verb in the message before assuming the binding is wrong. Three
different causes produce this:

- `cannot list resource "deployments"` — the Role has `get` but not `list` and
  `watch`. `kubectl rollout status` needs both; `get` alone is not enough. Fixed
  in `build-access.tf`, but check yours if you edited it.
- `cannot get resource "deployments/scale"` — `kubectl scale` uses the `scale`
  subresource, which is a separate grant from `deployments`.
- Only then: `build_namespace` and `build_service_account` do not match where
  the build pods actually run. Check them against the step group's
  `stepGroupInfra.spec.namespace` and re-apply.

If you set `build_namespace` to the delegate's namespace, you will not see this
error and you will not have tested anything — delegates usually run
cluster-admin, so the binding is moot.

**Stage 1 goes green-ish but there are no Roles in `dbops-ci`**
The apply created the namespace, Secret, Service, Deployment and CronJob and then
failed on all four Roles and RoleBindings. Kubernetes will not let a principal
create a Role granting permissions it does not itself hold, and both
`reaper.tf` and `build-access.tf` grant `deployments/scale`. Re-apply
`terraform/bootstrap/provisioner-rbac.yaml` — the version in this repo includes
it. The database will look perfectly healthy while the reaper silently cannot
scale it down. `ISSUES.md` issue 15.

**`psql: sql/migrations/V1__baseline.sql: No such file or directory`**
The `GitClone` step is green and the file is on disk — just not where the step is
looking. With `repoName` set, `GitClone` checks out into
`/harness/<repoName>/`, while the working directory stays `/harness`. Every step
that reads repo files needs `cd <repoName>` first. `cloneDirectory: /harness` is
rejected outright (`/harness is an invalid value`), so the `cd` is the fix.

If the clone step is genuinely missing: a Custom stage does not check out the
repository on its own, and `properties.ci.codebase` does not change that — only
CI stages read it. `DBSchemaApply` is unaffected either way, because it clones
the DB Schema's repository itself.

**Flyway: "found non-empty schema without schema history table"**
`globalSettings.baselineOnMigrate` is missing from the `DBSchemaApply` step.
The baseline was applied with `psql`, so Flyway meets a populated schema it has
no record of. With the setting on, Flyway baselines at V1 and starts at V2.

**Flyway tries to re-run V1 and fails on "relation already exists"**
The baseline spans more than `V1__baseline.sql`, so baselining at version 1
leaves later baseline files looking pending. Raise `baselineVersion` in
`globalSettings` to the highest version the `psql` step applies.

**Terraform 1.6+ rejected**
Only MPL versions up to 1.5.x are supported. Use OpenTofu instead — it's a
drop-in replacement here.

**`terraform init`: `x509: certificate signed by unknown authority`**
Your egress goes through a TLS-inspecting proxy. Set `CUSTOM_CA_PEM_B64` to a
secret holding `base64 < your-root-ca.pem | tr -d '\n'`. The confusing part is
how selective this is — image pulls, `GitClone` and the psql steps all work, and
the URL in the error is HashiCorp's, so it reads as a registry problem. Note that
committing `.terraform.lock.hcl` does not avoid it: the lock file pins versions,
but the provider binary is still downloaded.

**`init` succeeds, `apply` fails on the state lock**
The kubernetes backend locks with a Lease in `coordination.k8s.io`, not with the
state Secret. If the bootstrap Role covers `secrets` but not `leases`, `init`
looks fine and `apply` fails in a way that reads like state corruption.

**`terraform init`: no package available for your platform**
`.terraform.lock.hcl` was generated on a machine whose architecture differs from
your build nodes. Regenerate it for all of them:
`terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64`.

**Stage 3 is green but the database is still running**
The destroy could not see the provision's state, so it planned nothing and
reported no changes. Confirm `backend-kubernetes.tf.example` is being copied into
place by *both* stages, and that its `namespace` is a long-lived namespace rather
than `dbops-ci` — state stored in `dbops-ci` gets deleted by the destroy that
reads it. Always verify teardown with `kubectl get ns dbops-ci`, never with the
stage's status.

**`Unable to fetch port details ... check if 'Enable container based execution'
toggle is on for step group`**
If this is `DBSchemaApply` with `migrationType: Liquibase`, the message is
misleading and there is nothing to fix in your YAML — the step's Liquibase path
asks for a sub-step container that its own initialization never allocated. The
same step group runs Flyway and five other container steps green. Use the
Liquibase CLI in a `Run` step, as the shipped pipeline does. `ISSUES.md`
issue 13.

**Destroy stage skipped after a failure**
Check `when.pipelineStatus: All` on stage 3. Without it, failed runs leak
namespaces and you'll be cleaning up by hand within a week.

**Namespace stuck terminating**
Usually a finalizer on a leftover resource. For a demo cluster,
`kubectl patch namespace dbops-ci -p '{"metadata":{"finalizers":[]}}' --type=merge`
unsticks it.

**`namespaces "dbops-ci" is being deleted` on apply**
Back-to-back runs race the previous teardown: namespace deletion is
asynchronous, so an apply can arrive while the old namespace is still
terminating. The apply step retries three times for exactly this reason, which
covers it. If it exhausts the retries, the namespace is genuinely stuck — see
the entry above.

---

## The idle reaper

Stage 3 handles the normal case. The reaper handles everything else: a
cancelled run, a delegate that died after the apply, someone who hit stop.
Those all leave a database running, and a database that outlives its pipeline
is the shared staging problem growing back one namespace at a time.

A CronJob checks every 10 minutes. If the deployment's `harness.io/last-used`
annotation is older than `idle_ttl_minutes` (default 60), it scales the
deployment to zero.

**Why scale to zero rather than delete.** The database is stateless — there
is no volume to preserve and nothing to lose. Scaling to zero frees the
compute, which is the part that costs money, while leaving the Service and
its DNS name intact. That matters: deleting the namespace would take the
Service with it, and the JDBC connector would point at a name that no longer
resolves. Zero replicas keeps the connector valid pointing at something that
will answer again the moment the next run scales it back up.

Stage 2's first step handles both halves of that: it scales the deployment
back up if the reaper got there first, then refreshes the heartbeat so the
reaper doesn't scale the database out from under a long-running pipeline.

Tuning:

| Variable | Default | Notes |
|---|---|---|
| `idle_ttl_minutes` | `60` | Lower it to `15` on a busy shared cluster. |
| `reaper_schedule` | `*/10 * * * *` | Keep the interval well below the TTL. |
| `reaper_image` | `alpine/k8s:1.30.0` | Any image with `kubectl` on PATH. Not `bitnami/kubectl` — Bitnami moved its catalogue in 2025 and those tags no longer pull. A CronJob that cannot pull fails invisibly: no pipeline turns red, the databases just stop being reaped. |

**Verify it works** without waiting an hour — set the annotation into the
past and let the next tick fire:

```bash
kubectl annotate deploy ephemeral-db -n dbops-ci \
  "harness.io/last-used=2020-01-01T00:00:00Z" --overwrite

kubectl get deploy ephemeral-db -n dbops-ci -w   # replicas should hit 0
```

The reaper deliberately does nothing when the annotation is missing or
unparseable. An unannotated deployment may be mid-provision, and scaling that
down would be worse than leaving it up.
