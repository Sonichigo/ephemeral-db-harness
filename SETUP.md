# Setup Guide

Order matters here. The DB DevOps objects must exist before the pipeline
references them, and the JDBC connector must match the Terraform output
exactly or stage 2 will fail with a connection error that looks like a
network problem but isn't.

Estimated time: about an hour the first time, most of it in steps 2 to 5.

---

## Prerequisites

You bring the cluster. Everything past that is cloud agnostic — the Terraform
talks to the Kubernetes API and nothing else, so AKS, EKS, GKE, and
self-managed clusters are all the same from here.

- **Harness account with Database DevOps and IaCM enabled.** DB DevOps sits
  behind a feature flag (`DBOPS_ENABLED`); if the module isn't in the picker,
  that's why. IaCM is *not* optional any more: stages 1 and 3 of the shipped
  pipeline are real `IACM` stages and need a workspace to point at, which is
  step 2. If your account cannot turn IaCM on,
  `harness/custom-stages.yaml.example` holds the Custom-stage variant of those
  two stages and drops in over them — see the end of step 2.
- **A Harness Delegate running inside the target cluster.** Non-negotiable for
  stage 2: the delegate is what gives DB DevOps network access to a database
  that only exists at `ephemeral-db.dbops-ci.svc.cluster.local`. That is still
  true now that stages 1 and 3 run as IaCM, and it is still true if you move
  those two stages onto a Docker or Cloud runtime somewhere else entirely.
  Stage 2's requirement does not change either way.
- **A Git connector** pointing at the repo holding `sql/` and `terraform/`.
  The IaCM workspace points at the same connector.
- **A Docker registry connector.** Every container step needs one, and it must
  not be `account.harnessImage` — that connector rewrites image names to
  Harness's own registry and every pod lands in `ImagePullBackOff` with
  `manifest unknown`. `ISSUES.md` issue 2 has the detail.
- **A Kubernetes connector** for the target cluster. It does three jobs now:
  stage 2's step group build infrastructure, stages 1 and 3's
  `infrastructure.spec.connectorRef`, and the IaCM workspace's
  `provider_connector`.
- **The bootstrap RBAC applied once, by a cluster admin:**

  ```bash
  kubectl apply -f terraform/bootstrap/provisioner-rbac.yaml
  ```

  This is the "you bring the cluster and the permissions" part made explicit.
  It grants the build ServiceAccount what the Terraform needs and nothing more.
  Skip it and stage 1 fails `Forbidden` on the first namespace it tries to
  create. Edit the namespaces in that file if yours differ — the subject
  namespace has to match `<<HARNESS_BUILD_NAMESPACE>>` and `build_namespace`.

  On the primary path this is a hard prerequisite, not a nicety. The IaCM
  stages run their Terraform in a build pod in `<<HARNESS_BUILD_NAMESPACE>>`
  as that namespace's `default` ServiceAccount, and that SA is exactly the
  subject this file binds. There is no second identity to fall back to.

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

- **Outbound internet from the build pod.** `terraform init` downloads provider
  binaries from `registry.terraform.io` on every run, and committing
  `.terraform.lock.hcl` does not change that — the lock file pins versions and
  hashes, it does not cache anything. With egress blackholed, `init` fails with
  `Failed to query available provider packages ... could not connect to
  registry.terraform.io`. This was confirmed by blackholing egress with a
  complete lock file in place.

- **If your egress goes through a TLS-inspecting proxy** — the kind of corporate
  MITM appliance that re-signs every HTTPS connection — `terraform init` alone
  will fail on `x509: certificate signed by unknown authority` while image
  pulls, `GitClone` and the psql steps all work. `ISSUES.md` issue 14 explains
  why only that step notices.

  There are two routes, and they are not interchangeable. On the Custom-stage
  fallback, set the `CUSTOM_CA_PEM_B64` pipeline variable; that variable and the
  shell that consumes it now live in `harness/custom-stages.yaml.example`, not
  in the main pipeline, because no stage in the main pipeline reads it any more.
  On the IaCM path the equivalent is the workspace environment variable
  `PLUGIN_CA_CERT_PATH`, and it is not a drop-in swap: it takes a filesystem
  *path* to a single PEM file containing one or more certificates — a CA bundle,
  not a directory — and that file has to already be inside the container. On
  Kubernetes build infrastructure you get it there with the `volumes` or
  `podSpecOverlay` fields of the infrastructure spec. Its documented scope is
  also narrower than you want: it covers the provisioner *binary* download,
  whereas the failure in issue 14 is the *provider* download during `init`. The
  docs say the plugin additionally exports `SSL_CERT_FILE`, `CURL_CA_BUNDLE` and
  `SSL_CERT_DIR`, which would plausibly cover providers too — but that is our
  inference from the exported variable names, not a documented guarantee, and we
  have not run it behind a real inspecting proxy.

- **arm64 build nodes work, and are off the documented support matrix.** The
  IaCM delegate documentation tells you to tag delegates `Linux / Amd64` and
  the plugin-images page says custom-image binaries "need to be suitable for
  the amd64 architecture"; the strings `arm64` and `aarch64` appear nowhere on
  either page. Against that: the pipeline schema's `arch` enum is
  `[Amd64, Arm64]`, the `plugins/harness_terraform`, `harness/ci-addon`,
  `harness/ci-lite-engine` and `harness/drone-git` images all publish
  `linux/arm64`, and `terraform_1.5.7_linux_arm64.zip` exists. Our own testing
  ran on arm64 throughout. The honest framing: expect it to work, and do not
  expect to be able to escalate a break as a bug.

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

## Step 2 — Create the IaCM workspace

This is real work now, and it has to happen before step 6, because both the
provision and the destroy stage name the workspace by ID.

Stages 1 and 3 of `harness/pipeline-ephemeral-db-ci.yaml` are `IACM` stages
running on Kubernetes build infrastructure. Their `infrastructure` block is
`type: KubernetesDirect`, pointed at your Kubernetes connector and
`<<HARNESS_BUILD_NAMESPACE>>`. The IaCM Terraform plugin therefore executes in a
build **pod inside the target cluster**, with a projected ServiceAccount token
mounted at `/var/run/secrets/kubernetes.io/serviceaccount/`.

Three consequences, and they are the whole reason this path is the primary one:

- `kube_config_path` stays **empty**. The provider picks up the pod's in-cluster
  credentials, which is exactly what `main.tf`'s provider block was written for.
- There are **no `KUBE_*` variables to set**. If you have them from an earlier
  attempt, remove them — see the fallback subsection for why they are actively
  harmful here.
- `terraform/bootstrap/provisioner-rbac.yaml` is a **hard prerequisite**. The
  pod runs as the `default` ServiceAccount of `<<HARNESS_BUILD_NAMESPACE>>`,
  and that SA is the subject that file binds. The pipeline deliberately omits
  `serviceAccountName` so there is no way to drift off that binding by accident.

Earlier versions of this guide said IaCM could not reach a private cluster at
all. That was wrong, and the way it was wrong is instructive: `runtime.type`
really does accept only `Docker` and `Cloud`, and the platform really does say

```
Invalid yaml: $.pipeline.stages[0].stage.spec.runtime.type: does not have a value
in the enumeration [Docker, Cloud]
```

if you ask for `Kubernetes`. The mistake was concluding that `runtime` is how
you choose build infrastructure. It isn't — `infrastructure` is, and it accepts
`KubernetesDirect`. `ISSUES.md` issue 6 carries the correction.

### Workspace fields

IaCM module → **Workspaces** → **New Workspace**

| Field | Value |
|---|---|
| Name / identifier | `ephemeral-db-ci` |
| Provisioner | **OpenTofu**, or Terraform **≤ 1.5.x**. 1.6.0+ is BSL-licensed and not supported |
| Repository | your Git connector, path `terraform/` |
| Provider connector | the **Kubernetes connector** for the target cluster |
| `terraform_variables` | from `terraform/variables.tf` — see below |
| `environment_variables` | none on this path. Over the API, send `{}`; omitting it is a 400 |

The provider connector is required by the API even though this Terraform needs
no cloud credentials at all. That is not a contradiction you can argue your way
out of — the workspace will not be created without one, so point it at the
Kubernetes connector and move on. `ISSUES.md` issue 7.

`terraform_variables` is a **map keyed by variable name**, not a list, which
matters the moment you leave the UI. Set:

| Variable | Value | Notes |
|---|---|---|
| `db_password` | reference to the `ephemeral_db_password` secret | `value_type: secret`, and the value is the secret's **identifier**, not the password. Pass a literal and you store the password as a secret name |
| `build_namespace` | `<<HARNESS_BUILD_NAMESPACE>>`, e.g. `harness-builds` | Must match where stage 2's build pods actually run |
| `build_service_account` | `default` | Leave it. `default` is the only subject the bootstrap `ClusterRoleBinding` grants, so it is the only value that has been proven to work. Changing it means changing the bootstrap RBAC subject to match |

On the IaCM path the pipeline passes **no Terraform variables at all** — this
table is the only source, and whatever is not in it falls back to the `default`
in `terraform/variables.tf`. (An earlier edition of this guide said the pipeline
passes `TF_VAR_namespace` and `TF_VAR_build_namespace`; that is true only of the
Custom-stage fallback in `harness/custom-stages.yaml.example`, which sets them
as step-group environment variables. IACM stages have no such block.)

Two consequences:

- `namespace` is deliberately absent above, because `variables.tf` already
  defaults it to `dbops-ci` and that is what the shipped pipeline's
  `<<DB_NAMESPACE>>` is set to. If you change `<<DB_NAMESPACE>>` you must add
  `namespace` here to match, or stage 2 will look for the database in one
  namespace while stage 1 creates it in another — and the symptom is a
  connection timeout, not a missing-namespace error.
- `build_service_account` would fall back to `default` on its own. Setting it
  explicitly is for visibility, not behaviour.

Note the workspace ID when you are done. It goes into `<<IACM_WORKSPACE_ID>>`
in step 6, used by **both** stage 1 and stage 3.

### Creating it over the API

`harness/create-iacm-workspace.sh` does the above repeatably. It takes
`HARNESS_PAT`, `HARNESS_ACCOUNT_ID`, `HARNESS_ORG` and `HARNESS_PROJECT` from the
environment, and the PAT needs permission to create and edit IaCM workspaces.

This script has been **run against a real account**: it created workspace
`ephemeral_db` (provisioner `terraform 1.5.7`) on the first attempt, HTTP 200,
every field persisted, and that is the workspace the IACM stages then used for a
full provision-migrate-destroy cycle. The base path is `/gateway/iacm/api/...`
(`/iacm/api/...` also answers) — confirmed, not inferred. Its header still
records what that run did *not* settle, chiefly the `PUT`/update branch and the
`KUBE_FALLBACK=1` branch.

It sends **five** Terraform variables, two more than the table above: the three
listed there, plus `namespace` and `service_name` whenever `DB_NAMESPACE` and
`DB_SERVICE_NAME` are non-empty — and they default to `dbops-ci` and
`ephemeral-db`. So the script makes `namespace` explicit where the manual
instructions lean on the `variables.tf` default. Both end up at `dbops-ci`;
only the script shows you that it did.

The script exists rather than a one-line `curl` in this document because the
request body has a trap that the published OpenAPI spec cannot help you with.
Every entry in `terraform_variables` and `environment_variables` is a `Variable`
object, and `kind` is **required** — `"tf"` for Terraform variables, `"env"` for
environment variables. `kind` appears in `Variable.required` but is missing from
`Variable.properties` in the workspaces spec, and its enum `["env", "tf"]` is
only defined in the separate variables API. So a reader who correctly fixes
`provider_connector` and the map-versus-array problem still gets a third 400
with no field in the spec to explain it. `ISSUES.md` issue 7.

`value_type` is one of `string`, `secret`, `boolean`, `json` or `number`, and
`secret` means `value` is a reference to an existing Harness secret. Send a
literal password with `value_type: secret` and you have stored the password as a
secret *identifier*.

Two more shape details worth having in front of you: `org` and `project` are
**path segments** (`/api/orgs/{org}/projects/{project}/workspaces`), not query
parameters; the account goes in the `Harness-Account` **header**; and the auth
header is `x-api-key`. The script sends `accountIdentifier` as a query parameter
*as well*, belt-and-braces — the successful run sent both, so whether the header
alone suffices is still untested.

Still unverified after that run, so you are not surprised: whether `PUT` takes
the same body shape as `POST` (the workspace did not exist, so only the create
branch ran), the full accepted set of `provisioner` values (the spec types it as
a bare string with no enum; `terraform` works), and `provisioner_version` values
other than `1.5.7`.

### Fallback — Docker or Cloud runtime

Skip this unless you cannot use Kubernetes build infrastructure. These are the
`runtime.type` values from the error above, and they both run the Terraform
*outside* the cluster: `Cloud` on Harness-hosted infrastructure, `Docker` as a
container on the delegate host. Neither gets a ServiceAccount token, so the
provider has to be handed credentials as workspace environment variables.

Three of them, and the encodings are not guessable. These were verified by a
full apply and destroy from outside the cluster against Terraform 1.5.7 and
`hashicorp/kubernetes` 2.38.0, with `main.tf` unchanged:

| Variable | Value |
|---|---|
| `KUBE_HOST` | the full URI including scheme, e.g. `https://1.2.3.4:6443` |
| `KUBE_CLUSTER_CA_CERT_DATA` | **raw PEM**, including the `-----BEGIN CERTIFICATE-----` lines |
| `KUBE_TOKEN` | the raw JWT |

Despite the `_DATA` suffix, `KUBE_CLUSTER_CA_CERT_DATA` is not base64. Base64
fails with

```
Error: Failed to configure client: unable to load root certificates: unable to parse bytes as PEM block
```

which reads like a corrupt certificate rather than a wrong encoding, and will
cost you an afternoon.

**These three must be absent on the KubernetesDirect path.** They override
in-cluster auth, so a leftover `KUBE_HOST` from an experiment sends the build
pod's Terraform at whatever that variable still says.

Four more things about this path, each of which produces a wrong answer rather
than an error:

- **`KUBE_CONFIG_PATH` silently wins.** The provider does not read `KUBECONFIG`,
  but it does read `KUBE_CONFIG_PATH` and `KUBE_CONFIG_PATHS`. Because
  `kube_config_path = ""` makes `config_path` null, that null activates the
  provider's env-var default — and a kubeconfig found that way takes precedence
  over `KUBE_TOKEN` with no warning. Proven: `KUBE_CONFIG_PATH` set alongside a
  deliberately invalid `KUBE_TOKEN` produced `No changes. Your infrastructure
  matches the configuration.` Unset both explicitly on this path.
- **`terraform plan` does not authenticate.** On an all-new configuration, plan
  never contacts the API server, so it succeeds with a completely bogus token.
  Only `apply`, or a plan that refreshes existing state, authenticates.
  Validating these variables with a plan gives you a false pass.
- **Read the error for the identity.** A valid-but-unprivileged token gives
  `Forbidden` and names the ServiceAccount. A malformed token gives a bare
  `Error: Unauthorized` with no identity in it. Only the `Forbidden` case tells
  you which identity is actually in play.
- **The default token lasts one hour.** On Kubernetes 1.32 a ServiceAccount has
  no auto-created token Secret, and `kubectl create token` defaults to exactly
  3600 seconds with no warning. A token pasted into a Harness secret that way
  starts failing with `Unauthorized` about an hour later, which looks like RBAC
  or connectivity. For a stored credential, create an explicit
  `kubernetes.io/service-account-token` Secret instead; that token has no `exp`
  claim. Do not reach for `kubectl create token --duration=8760h` — it is capped
  by the apiserver's `--service-account-max-token-expiration`, which happened to
  be unset on our test cluster and is clamped on managed EKS, AKS and GKE
  control planes.

`terraform/bootstrap/provisioner-rbac.yaml` carries the manifests for this at
the end of the file, **commented out**: a named `ephemeral-db-provisioner`
ServiceAccount in `harness-builds`, bindings of the existing ClusterRole and
state Role to it, and a long-lived token Secret. Uncomment that block and
re-apply the file to enable the fallback; leave it alone otherwise.

They are commented rather than merely labelled optional because
`kubectl apply -f` applies every document in a file — there is no way to apply
the primary path and "skip the optional section" in the same command. Since the
ClusterRoleBinding there gives a never-expiring token cluster-wide
`deployments` and `deployments/scale`, the safe default is for it not to exist
until you ask for it. The file's
default bindings target `harness-builds:default`, which is a pod identity — the
fallback has no pod, and therefore no token, until you create one.

One scoping consequence to say out loud: on this path `build-access.tf` grants
nothing to the actual caller, because the caller is not a build pod in the
cluster. Stage 2's wake step then depends on the existing
`ephemeral-db-provisioner` ClusterRole, which already carries
`deployments` get/list/watch/patch and
`deployments/scale` get/update/patch **cluster-wide**. That is a broader grant
than the in-cluster path needs.

### Fallback — Custom stages instead of IaCM

If your account has no IaCM module, or you want the configuration with the most
green-run evidence behind it, `harness/custom-stages.yaml.example` holds stages
1 and 3 as Custom stages: a `KubernetesDirect` step group running
`hashicorp/terraform:1.5.7`, with `GitClone`, the CA-bundle shell, the backend
copy, and `terraform init` plus `apply` or `destroy`. Paste those two stages
over stages 1 and 3 and keep stage 2 as it is.

What you give up: the Resources tab, drift detection, cost estimation and a plan
artifact you can gate on. What you take on: **state is yours**. You have to copy
`terraform/backend-kubernetes.tf.example` into place in both stages, and you
have to keep `secret_suffix` unique per cluster — it is hardcoded, so two
pipelines or two `DB_NAMESPACE` values against one cluster share a single state
object and the loser's destroy plans against the winner's resources. The fix is
`-backend-config=secret_suffix=...` at `init`, since `secret_suffix` cannot be a
variable inside a backend block.

That whole category of problem is the reason the IaCM path is primary: on it,
the platform owns state, and there is no backend block to get wrong. Which is
also why you should **not** commit a `backend-kubernetes.tf` into `terraform/`
— the IaCM workspace reads that directory, and a stray backend block there
diverts state away from the platform.

### Optional gates, both off by default

Neither an OPA policy gate nor an approval step is enabled in the shipped
pipeline. Both are available, and both have a reason they are off:

- An **`IACMApproval` step holds the build pod.** Per the docs, "the underlying
  machine running the pipeline remains active until the approval is resolved.
  This means it will continue consuming compute resources", and "the approval
  plan step has a timeout of up to 60 minutes ... Upon timeout, the pipeline
  fails." That widens exactly the window in `ISSUES.md` issue 10, where a run
  cancelled between the apply and the wake step leaks a database permanently.
- The **OPA gate fails open if you wire it at the step level.** It has to be a
  policy set with entity type **Terraform Plan** and evaluation event **After
  Terraform Plan**, which fires automatically. The docs are explicit: "You do
  not attach them in the plan or apply step's policy configuration UI ... It
  will not appear there. This is expected behavior." Attach some other entity
  type to a plan step and "the plan step does not pass the Terraform plan JSON
  as input to the policy", so "the policy can pass even when the plan violates
  the policy rules" — a green gate that checked nothing. Rego reads
  `input.planned_values` and `input.resource_changes`. Confirm it is actually
  receiving a plan on the policy set's **Evaluations** tab, which "shows the
  exact input payload passed to the policy."

### What to verify later, and why it belongs to this step

The check that the workspace is wired correctly is a *run*, and you have no
pipeline to run until Step 6 — so the check itself lives at the end of Step 7.
It is described here because what it catches is a workspace-level mistake, and
you will have forgotten this page by the time you see the symptom.

The check is: run just stage 1, then just stage 3, and confirm the namespace is
gone. What you are testing is not that stage 1 goes green — it is that stage 3
**destroys something**.

A destroy that cannot see the provision's state prints "no changes" and goes
green over a database that is still running. This is not hypothetical; it was
reproduced deliberately on minikube. A fresh pod with local state printed

```
No changes. No objects need to be destroyed.
```

and exited 0 while `kubectl get ns` still showed the namespace `Active`. Shared
state is load-bearing, and the IaCM path removes this failure mode by making the
platform own state rather than the pipeline. Verify teardown with `kubectl`
anyway. The stage's status is not evidence.

### What is and is not proven here

Be clear-eyed about the provenance of the two paths, because they are not
equally tested.

The Terraform itself has been run hard. Four pod runs in `harness-builds` as
the `default` ServiceAccount, with no kubeconfig and `main.tf` unchanged: two
full applies of 10 resources and two full destroys of 10, 40 resource
operations with zero `Forbidden` errors. Postgres reached Ready and a `psql`
connection over the exact `jdbc_url` output succeeded against
`PostgreSQL 16.4`. A destroy from a *separate* pod over shared state left
`kubectl get ns` returning `NotFound` for the database namespace. So the RBAC in
`provisioner-rbac.yaml` is sufficient as written for the primary path, and the
provider resolving to `hashicorp/kubernetes` 2.38.0 from the committed lock file
is confirmed. The reaper CronJob was created and configured correctly; its
*script* was not exercised, because no tick was awaited.

The IaCM stages themselves have since been **executed on `app.harness.io`**,
which supersedes an earlier edition of this paragraph saying they were
schema-validated only and had never run. What ran: the workspace was created over
the API, stage 1 alone provisioned the database with no credential configuration
at all, the Resources tab returned ten resources, stage 3 alone left `dbops-ci`
`NotFound`, a deliberately failed migration still destroyed, and the full
pipeline went green end to end under both Flyway and Liquibase. `ISSUES.md` has
the detail, including the three blockers that only showed up once the stages
actually ran — `allowStageExecutions`, `branch: <+input>`, and `Initialize`
validating steps it is about to skip.

Two gaps remain in that tier and they are worth knowing before you rely on
either: the IaCM workspace **outputs** endpoint could not be found, so `jdbc_url`
appearing in the Resources tab is unconfirmed, and the Docker/Cloud fallback
below has never been executed.

Schema validation is still what you get before you run anything, and it is a
weaker claim than it sounds. The IaCM stage schema
sets `additionalProperties: false` nowhere, so an invented or misplaced key
validates cleanly and is simply ignored at runtime, and
`IACMStageConfigImpl.required` is only `["execution"]` — a dropped
`infrastructure` block validates and the stage then runs somewhere you did not
intend. Treat a clean schema check as "the YAML is well-formed", never as "this
will work".

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

**For Liquibase, create a second schema — this is not optional.** Name it
`orders_schema_liquibase`, point it at `sql` (not `sql/migrations`), set
Migration Type **Liquibase** and give it the changelog
`db.changelog-master.xml`. The changelog references the same migration files, so
both tools apply byte-identical SQL.

Two reasons it is not optional, both learned the hard way:

- The shipped pipeline's Liquibase branch is a real `DBSchemaApply` step, not a
  CLI `Run` step. An earlier edition of this guide said otherwise, citing a
  platform bug; that was a misdiagnosis and `ISSUES.md` issue 13 is now the
  retraction. The actual requirement is that a Liquibase `DBSchemaApply` needs a
  **Liquibase-typed** schema and instance — reusing the Flyway pair is what
  fails, with a message about container-based execution that sends you looking
  in the wrong place entirely.
- You need it even if you only ever intend to run Flyway. `Initialize` resolves
  schema and instance references for every declared step, including the Liquibase
  one it is about to skip, so a missing Liquibase schema fails the **Flyway**
  run. `ISSUES.md` issue 25.

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

**Then repeat this step inside the Liquibase schema**, naming the instance
`ephemeral_ci_liquibase`. Same JDBC connector, same context, same branch — the
instance is per-schema, so the Flyway one is not visible to the Liquibase schema
and cannot be reused. Over the API the path is singular and undocumented:

```
GET /gateway/v1/orgs/{org}/projects/{proj}/dbschema/{schema}/instance
```

`dbschema` for the parent, `instance` for the child. Every plural spelling 404s.
`ISSUES.md` issue 27. Use that to list what already exists rather than guessing
identifiers — guessing one is what produced the issue-25 failure above.

---

## Step 6 — Wire up the pipeline

Take `harness/pipeline-ephemeral-db-ci.yaml` and replace:

| Placeholder | Value |
|---|---|
| `<<PROJECT_ID>>` / `<<ORG_ID>>` | your project and org |
| `<<GIT_CONNECTOR>>` | Git connector ref |
| `<<REPO_NAME>>` | repo the `GitClone` step checks out, e.g. `ephemeral-db-harness` |
| `<<REPO_BRANCH>>` | branch that `GitClone` step checks out, e.g. `main`. Must be a literal — see the note below |
| `<<K8S_CONNECTOR>>` | Kubernetes connector ref. Stages 1 and 3 use it as `infrastructure.spec.connectorRef`, stage 2 as its step group infrastructure |
| `<<IACM_WORKSPACE_ID>>` | the workspace from step 2. Used by **both** stage 1 and stage 3 — if they disagree, the destroy reads state the apply never wrote |
| `<<DOCKER_CONNECTOR>>` | Docker registry connector ref. **Not** `account.harnessImage` |
| `<<HARNESS_BUILD_NAMESPACE>>` | namespace for build pods, e.g. `harness-builds`. Must match `build_namespace` and the bootstrap RBAC subject. Not your delegate's namespace |
| `<<DB_HOST>>` | `ephemeral-db.dbops-ci.svc.cluster.local` |
| `<<DB_NAMESPACE>>` | `dbops-ci` |
| `<<DB_SCHEMA_FLYWAY>>` | `orders_schema` from step 4 |
| `<<DB_INSTANCE_FLYWAY>>` | `ephemeral_ci` from step 5 |
| `<<DB_SCHEMA_LIQUIBASE>>` | `orders_schema_liquibase` from step 4. A separate schema is unavoidable: `migrationType` is fixed on the DB Schema and cannot be an expression |
| `<<DB_INSTANCE_LIQUIBASE>>` | the instance attached to that schema, from step 5 |

One pipeline variable, at the top of the file:

- `MIGRATION_TOOL` — `Flyway` or `Liquibase`, defaults to `Flyway`. Selects
  which of the two apply steps runs; the other reports `Skipped`.

**Do not turn any of these into `<+input>`.** The `GitClone` branch in stage 2
was a runtime input and it does not work. The Custom stage's `Initialize` step
builds the container environment for the whole step group before any step runs,
and a branch left to runtime input is still empty then, so the stage dies with
`[Environment variable DRONE_COMMIT_BRANCH can't be empty or null]`. That names
a Drone variable nothing in the pipeline mentions, and stages 1 and 3 pass
either side of it, so it reads like a migration bug. Supplying the branch in
exactly the shape `GET /pipeline/api/inputSets/template` returns does not help —
this was reproduced three times on `app.harness.io`. `MIGRATION_TOOL` is a
pipeline *variable*, not a step field, and is the one runtime input that works.

`CUSTOM_CA_PEM_B64` used to live here too. It is gone from the main pipeline
because no stage in it reads the variable any more — it moved into
`harness/custom-stages.yaml.example` along with the two Terraform `Run` steps
that consumed it. The IaCM equivalent is the workspace environment variable
`PLUGIN_CA_CERT_PATH`, with the caveats in the prerequisites.

If you are swapping in `harness/custom-stages.yaml.example` for stages 1 and 3,
that file needs `CUSTOM_CA_PEM_B64` added back as a pipeline variable and does
not need `<<IACM_WORKSPACE_ID>>`.

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

**Run 3 — prove the teardown.** This is the check Step 2 deferred, and it is the
one that distinguishes a working pipeline from one that merely reports green.
Using selective stage execution, run **stage 1 on its own**, confirm the
database is up, then run **stage 3 on its own**:

```bash
kubectl get ns dbops-ci    # must come back NotFound
```

Two separate executions, not one run with stages skipped — the point is that
stage 3 can find the state stage 1 wrote without stage 1 being in the same
execution. If the stage picker is missing from the run dialog, the pipeline is
missing `allowStageExecutions: true`; `ISSUES.md` issue 23.

A stage-3 run that prints `No changes. No objects need to be destroyed.` and
goes green has not found the state. Read the Terraform log, not the stage status.

**Run 4 — prove the destroy survives a failure.** Re-run the broken migration
from Run 2 and watch stage 3 specifically. Stage 2 goes red; stage 3 must still
execute and still leave the namespace `NotFound`. That behaviour comes from
`when: pipelineStatus: All` on stage 3, and it is what stops a failed demo from
leaving a database running until someone notices the bill. If stage 3 is
`Skipped` here, that `when` block has been edited out.

**Run 5 — the other migration tool.** Set the `MIGRATION_TOOL` pipeline variable
to `Liquibase` in the run dialog. The same five SQL files are applied through
`sql/db.changelog-master.xml` instead, through a `DBSchemaApply` step identical
to the Flyway one but for `migrationType` — so the broken-migration demo fails
the same way under either tool. The unselected tool's step should report
`Skipped`, not vanish from the graph.

This is the one place a runtime input is used, and it works because
`MIGRATION_TOOL` is a pipeline variable consumed by a `when` condition. Setting
it over the API is a different matter — see `ISSUES.md` issue 26, where the
execute endpoint accepts a value and ignores it.

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
Your egress goes through a TLS-inspecting proxy. On the Custom-stage fallback,
set `CUSTOM_CA_PEM_B64` to a secret holding
`base64 < your-root-ca.pem | tr -d '\n'`. On the IaCM path, mount the CA bundle
into the build pod and set `PLUGIN_CA_CERT_PATH` to its path — see the
prerequisites, where the differences are spelled out, because it is not a
rename. The confusing part is how selective this is — image pulls, `GitClone`
and the psql steps all work, and the URL in the error is HashiCorp's, so it
reads as a registry problem. Note that committing `.terraform.lock.hcl` does not
avoid it: the lock file pins versions, but the provider binary is still
downloaded.

**`terraform init`: `could not connect to registry.terraform.io`**
The full text is `Failed to query available provider packages ... could not
connect to registry.terraform.io`. The build pod has no outbound internet. The
committed lock file does not save you here either — it pins versions and
hashes, it does not cache binaries, and this was confirmed by blackholing egress
with a complete lock file in place. Either open egress for the pod or stand up a
provider mirror. `PLUGIN_BINARY_DIR` is not the answer on its own: it pre-bakes
the `terraform`/`tofu` *binary* only, providers are still fetched during `init`,
and it degrades silently — if none of the binaries match, the plugin downloads
the required version at runtime instead.

**Stage 1 fails `Forbidden` on the very first namespace**
Either `terraform/bootstrap/provisioner-rbac.yaml` was never applied, or the
stage's `infrastructure.spec` names a `serviceAccountName` that the bootstrap
file does not bind. The shipped pipeline omits `serviceAccountName` on purpose
so the pod runs as `<<HARNESS_BUILD_NAMESPACE>>`'s `default` SA, which is the
only subject that binding covers. If you added one, either remove it or add the
matching subject to the `ClusterRoleBinding`. Read the error for the
ServiceAccount name — a `Forbidden` names the identity, which is how you tell
this apart from a token problem.

**`Error: Unauthorized` about an hour into the Docker or Cloud fallback**
The token expired. `kubectl create token` defaults to exactly one hour on
Kubernetes 1.32 and says nothing about it, so `KUBE_TOKEN` works, then stops,
and the symptom looks like RBAC or connectivity. Create an explicit
`kubernetes.io/service-account-token` Secret and use that token, which has no
`exp` claim. Note the asymmetry with the entry above: a bare `Unauthorized` with
no identity in it means the token is bad, while `Forbidden` naming an SA means
the token is fine and the RBAC isn't.

**The pipeline saved cleanly and still behaves wrongly**
A clean save is a weak signal. The IaCM stage schema sets
`additionalProperties: false` nowhere, so `delegateSelectors` indented one level
too far under `spec:` validates and is then ignored at runtime, and
`IACMTerraformPluginInfo.command` is a bare string with no enum, so
`plan-destory` or `initialise` validates and fails only when the step runs. For
stage 3 that means a typo surfaces during teardown of real infrastructure, in
the path that runs with `when.pipelineStatus: All`. Check the command spellings
against the documented set: `init`, `plan`, `apply`, `destroy`, `plan-destroy`,
`plan-refresh-only`, `apply-refresh-only`, `detect-drift`, `validate`, `fmt`,
`import`, `removed`.

**Harness rejects the YAML with a wall of unrelated errors**
`pipeline.stages[].stage` is a `oneOf` across all thirteen stage types, so one
real mistake produces about fourteen errors, most of them noise — `'IACM' is not
one of ['Deployment']`, `['CI']`, `['Custom']`, and so on. The one that matters
is the branch whose `schemaPath` contains `oneOf/0/allOf/0/then/`. The UI often
shows only the first error, which is usually one of the useless ones.

**`init` succeeds, `apply` fails on the state lock**
Custom-stage fallback only — on the IaCM path there is no backend to lock. The
kubernetes backend locks with a Lease in `coordination.k8s.io`, not with the
state Secret. If the bootstrap Role covers `secrets` but not `leases`, `init`
looks fine and `apply` fails in a way that reads like state corruption. Note
that the Lease only serializes *concurrent* access to one state object; it does
not keep two unrelated pipelines sharing a `secret_suffix` apart.

**`terraform init`: no package available for your platform**
`.terraform.lock.hcl` was generated on a machine whose architecture differs from
your build nodes. Regenerate it for all of them:
`terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64`.

**Stage 3 is green but the database is still running**
The destroy could not see the provision's state, so it planned nothing and
reported no changes — verbatim, `No changes. No objects need to be destroyed.`
with exit 0. Reproduced on minikube; this is the failure mode stage 3 exists to
prevent, wearing a green tick.

On the IaCM path this should not be possible, because the platform owns state.
If it happens anyway, check two things: that `<<IACM_WORKSPACE_ID>>` is the same
value in stage 1 and stage 3, and that no `backend-kubernetes.tf` has been
committed into `terraform/`. A backend block in the workspace's directory
diverts state away from the platform and reintroduces exactly this leak.
`terraform/backend-kubernetes.tf.example` keeps its `.example` suffix for that
reason.

On the Custom-stage fallback, state is yours: confirm
`backend-kubernetes.tf.example` is being copied into place by *both* stages,
that its `namespace` is a long-lived namespace rather than `dbops-ci` — state
stored in `dbops-ci` gets deleted by the destroy that reads it — and that
`secret_suffix` is unique to this pipeline and cluster.

Either way, verify teardown with `kubectl get ns dbops-ci`, never with the
stage's status.

**`Unable to fetch port details ... check if 'Enable container based execution'
toggle is on for step group`**
If this is `DBSchemaApply` with `migrationType: Liquibase`, ignore what the
message tells you to check — the step group is container-based and the toggle is
not the problem. Check instead that the **DB Schema and DB Instance you pointed
it at are themselves Liquibase**, not the Flyway pair. That is the configuration
that produces this error, and a dedicated `orders_schema_liquibase` /
`ephemeral_ci_liquibase` pair runs green in the same step group. `ISSUES.md`
issue 13, which is a retraction of an earlier claim that this could not be made
to work at all.

**`Environment variable DRONE_COMMIT_BRANCH can't be empty or null`, at
`Initialize`**
The `GitClone` step's `branch` is a runtime input. It cannot be — `Initialize`
builds the step group's environment from the YAML before any step runs, and a
runtime input is not substituted yet, so supplying the value at trigger time
does not help. Make it the setup-time `<<REPO_BRANCH>>` placeholder. The error
names a Drone variable that appears nowhere in this repo and the clone step
never ran, so do not go looking at the clone step. `ISSUES.md` issue 24.

**`instance with id [...] schema [...] does not exist` for a tool you are not
using**
Same cause, second guise: `Initialize` resolves `DBSchemaApply`'s schema and
instance references for **every** declared step, including the one whose `when`
is false and which the run will correctly report as `Skipped`. So both
schema/instance pairs must exist and be correct before either tool can run.
`ISSUES.md` issue 25.

**The run dialog offers no way to run a single stage**
The pipeline is missing `allowStageExecutions: true`. Over the API the same
cause gives `HTTP 400 — Stage executions are not allowed for pipeline`.
`ISSUES.md` issue 23.

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
