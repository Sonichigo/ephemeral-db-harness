# ephemeral-db-harness

A database that did not exist a minute ago, proves your migration, and is gone before the pipeline exits.

Harness IaCM provisions it. Harness Database DevOps migrates it. IaCM destroys it — including when the migration fails. A CronJob catches the runs that never reach teardown at all.

```
Stage 1 (IaCM)          Stage 2 (DB DevOps)        Stage 3 (IaCM)
init/plan/apply    ->   clone, wake, seed,    ->   init/plan-destroy/destroy
                        apply, verify              when: pipelineStatus: All

  1 and 3 run in a KubernetesDirect build pod inside the target cluster,
  so Terraform authenticates as that pod's ServiceAccount

            CronJob: scales to zero after 1h unused
```

## Cloud agnostic

The Terraform talks to the Kubernetes API and nothing else. AKS, EKS, GKE, self-managed — same module, same variables. You bring the cluster and a Harness delegate running inside it.

The IaCM stages run inside that same cluster, as a build pod with a mounted ServiceAccount token. So they need no cloud credentials either — no kubeconfig, no cluster endpoint, no CA bundle to paste into a secret. The identity is the pod.

## Layout

```
terraform/
  main.tf          Stateless Postgres: fresh pod every run, constant Service DNS name.
  reaper.tf        CronJob + scoped RBAC. Scales to zero after idle_ttl_minutes.
  build-access.tf  Lets the pipeline's build pods scale and annotate the database.
  variables.tf     No cloud credentials. Only db_password is secret.
  outputs.tf       jdbc_url and friends. IaCM owns the state now, so these are
                   the workspace's own outputs rather than a build pod's, which
                   is what the Resources tab reads.
  jdbc-connector.tf.example
                   Optional: have IaCM own the JDBC connector instead of
                   creating it by hand. Drop the .example suffix to use it.
  backend-kubernetes.tf.example
                   Remote state in a Kubernetes Secret. For the Custom-stage
                   fallback only — IaCM owns state on the primary path, and a
                   stray backend block there would divert it. Without shared
                   state the destroy plans against nothing and leaks the
                   database while going green.
  bootstrap/
    provisioner-rbac.yaml
                   The one-time grant a cluster admin applies before the first
                   run. Everything else here is applied by the pipeline; this
                   is what lets the pipeline apply anything.
harness/
  pipeline-ephemeral-db-ci.yaml
                   The three-stage pipeline. Provision, migrate, destroy.
                   Stages 1 and 3 are IACM stages on Kubernetes build
                   infrastructure; stage 2 is Database DevOps.
  custom-stages.yaml.example
                   Stages 1 and 3 as a Custom stage running Terraform directly.
                   The path with green-run evidence behind it, and the one to
                   use on an account without IaCM.
  create-iacm-workspace.sh
                   Creates the IaCM workspace over the API, so setup is
                   repeatable instead of a form filled in by hand. Needs a PAT.
sql/
  migrations/      V1 baseline + V2 (the migration under test).
  db.changelog-master.xml
                   Liquibase changelog over the same migration files, so both
                   tools apply byte-identical SQL.
  seed/            Production-shaped rows, including edge cases.
  checks/          Six assertions that gate the pipeline.
  broken/          Passes on an empty DB, fails on a seeded one.
SETUP.md           Step-by-step wiring guide. Start here.
ISSUES.md          What broke when this was first run against a real cluster,
                   with causes. Read it before debugging anything.
```

## The demo

```sql
ALTER TABLE orders ADD COLUMN status TEXT NOT NULL;
```

Against an empty database: `ALTER TABLE`. Green. Against the seeded database this pipeline provisions:

```
ERROR: column "status" of relation "orders" contains null values
```

Same SQL. The one that told the truth had rows in it.

## Two design choices worth knowing before you read the code

**The database is disposable; the address is stable.** DB Instances in
Harness require fixed connectors — you cannot pass one as an expression. So
the Service DNS name is constant and everything behind it is new every run.

That constraint has a second, often better answer: let IaCM provision the connector itself, keeping its identifier fixed while Terraform rewrites its URL on every apply. That is the only workable route for a managed database that hands you a new endpoint each time it is created, and it is sketched in `terraform/jdbc-connector.tf.example`. This repo uses the constant-address route because an in-cluster Service already gives you a constant address for free.

**Stateless, so shutdown is free.** `emptyDir`, no PVC. Nothing to preserve, so the reaper can scale to zero and the next run scales back up into a clean database.

## What has been run

Being precise about this, because "it looks right" is how the `NOT NULL` bug at
the top of this README ships in the first place. Three tiers, kept apart because
they attest to different things: green pipeline runs on a real account using the
Custom-stage provisioning path, direct minikube runs establishing the mechanism
the IaCM stages rely on, and green runs of the **IACM stages themselves** on a
real account — the newest tier, which replaces an earlier edition of this
section that said those stages had never been run.

**Green on app.harness.io, with provisioning as a Custom stage.** All three
stages ran green against minikube on colima, from an empty cluster to a
destroyed namespace, on both migration tools. Stages 1 and 3 were the
Custom-stage Terraform that now lives in `harness/custom-stages.yaml.example`,
so these timings attest to the fallback path, not to the IaCM path:

| Tool | Provision | Migrate | Destroy | Total |
|---|---|---|---|---|
| Flyway | 102s | 146s | 81s | 5m34s |
| Liquibase | 94s | 87s | 52s | 3m56s |

Verified against PostgreSQL 16.4, Flyway 10.22 and Liquibase 4.29:

- Happy path: baseline, seed, `V2`, then all six checks pass.
- Broken migration fails on a seeded database with
  `column "status" of relation "orders" contains null values`, and applies
  cleanly on an empty one. That contrast is the demo, it holds, and it holds
  identically under both tools.
- The checks derive expected row counts from the seed: add rows and they still
  pass, and they refuse to pass at all if the seed step did not run.
- Flyway with no `baselineOnMigrate` reproduces
  `Found non-empty schema(s) "public" but no schema history table`. With it set,
  Flyway baselines at V1 and applies V2 — which is why the pipeline sets it.
- Reaper, both branches: scaled to zero when idle past the threshold, left alone
  when there was no heartbeat to judge. Then the wake path scaled it back up and
  the run went green through verify.
- Terraform in a build pod with no kubeconfig and no cloud credentials, state in
  a Kubernetes Secret. The destroy stage leaves `dbops-ci` `NotFound`.

**Proven on minikube directly, which is what the IaCM design rests on.**
Terraform 1.5.7 in a pod in namespace `harness-builds`, as ServiceAccount
`default`, no kubeconfig, `terraform/main.tf` unchanged, on minikube v1.32.0:

- Four pod runs — two full applies and two full destroys, ten resources each,
  forty resource operations — with zero `Forbidden` errors. So
  `terraform/bootstrap/provisioner-rbac.yaml` is sufficient as written for this
  path, and the move to IaCM needs no RBAC change.
- The credential was the projected token at
  `/var/run/secrets/kubernetes.io/serviceaccount/`. That is exactly the identity
  `main.tf`'s provider block already expects when `kube_config_path` is empty,
  which is why the Terraform needs no functional change either. The provider
  resolved to `hashicorp/kubernetes` v2.38.0 from the committed lock file.
- Postgres reached Ready and `psql` connected over the exact `jdbc_url` output —
  `jdbc:postgresql://ephemeral-db.dbops-ci-v1.svc.cluster.local:5432/app_test` —
  and reported `PostgreSQL 16.4`.
- Destroy, run from a *separate* pod against the shared state, removed all ten
  resources and left `kubectl get ns dbops-ci-v1` at `NotFound`.
- The reaper CronJob was created — `*/10 * * * *`, `Forbid`, not suspended — and
  `harness.io/last-used` got a real value from the `timestamp()` fallback. The
  reaper *script* was not exercised; no tick was awaited. Nothing here
  re-verifies the reaper logic.
- The silent-leak failure mode was reproduced on purpose: a fresh pod with
  *local* state prints `No changes. No objects need to be destroyed.` and exits
  0 while the namespace stays `Active`. Shared state is load-bearing for exactly
  this reason, and under IaCM the platform owns the state, which is what takes
  this failure mode off the table.
- `terraform init` needs outbound internet even with a complete lock file. With
  egress blackholed it fails with `could not connect to registry.terraform.io`.
  The lock file pins versions; it does not remove the network dependency.

**Green on app.harness.io as IACM stages.** This is the tier that was missing,
and it is now the one the shipped pipeline rests on. Workspace `ephemeral_db`,
provisioner `terraform 1.5.7`, against the same cluster:

- The IaCM workspace was created over the API by
  `harness/create-iacm-workspace.sh` on the first attempt, and
  `type: IACM` with `infrastructure: type: KubernetesDirect` was accepted by
  `POST /pipeline/api/pipelines/v2`. The second of those settles the question
  `ISSUES.md` issue 6 got wrong twice.
- **Stage 1 alone** provisioned the namespace, a `1/1` Postgres Deployment, the
  stable `ClusterIP` Service and the reaper CronJob — with **zero credential
  configuration**. No kubeconfig, no `KUBE_*` variables, just the build pod's own
  projected ServiceAccount token, exactly as the minikube tier predicted.
- **The Resources tab exists and is populated:** ten resources.
- **Stage 3 alone, run after stage 1 alone**, took `dbops-ci` from `Active`
  through `Terminating` to `NotFound`. This is the check that distinguishes a
  real destroy from a green tick over empty state, and it is the reason the
  pipeline carries `allowStageExecutions: true`.
- **A failed migration still destroys.** Provision Success, Migrate Failed,
  Destroy Success, namespace `NotFound` — so the `when: pipelineStatus: All` on
  stage 3 does what it claims, which is the whole point of an ephemeral database.
- **Full pipeline green end to end under both tools**, Flyway and Liquibase, each
  through a real `DBSchemaApply` step, with the unselected tool's step reporting
  `Skipped`.

Two things in this tier are still open, and they are in `ISSUES.md` as issues 26
and 28 rather than glossed here: the IaCM workspace **outputs** endpoint could
not be found at all, so "`jdbc_url` visible in the Resources tab" is the one
acceptance check with no evidence behind it; and the Docker/Cloud runtime
fallback has never been executed, because the Kubernetes runtime worked.

**Still not observed:** cost estimation and drift detection. Both are claimed
from Harness documentation. Getting the stages onto IaCM is what makes them
available; it is not the same as having watched them work.

**And one standing caveat: arm64.** Everything above ran on arm64 — colima on
Apple silicon. Harness documents only Amd64 for IaCM: the delegate page says to
tag delegates Linux / Amd64 and never mentions arm64 or aarch64, and the
custom-image docs say binaries need to suit amd64. Against that, the pipeline
schema's `arch` enum is `[Amd64, Arm64]`, the plugin and CI images publish
`linux/arm64`, and `terraform_1.5.7_linux_arm64.zip` exists. Those are our
findings, not a Harness statement of support. So: it works, it is off the
documented support matrix, and if it breaks that is not escalatable as a bug.

**Read `ISSUES.md` before debugging anything.** Getting to those green runs
turned up the problems catalogued there, and in four cases the symptom already
had a troubleshooting entry in SETUP.md that named the wrong cause. One is still
open by choice rather than fixed: Liquibase runs through the CLI instead of
`DBSchemaApply` (issue 13, a platform bug). Issue 6 — provisioning as a Custom
stage — is now closed, and worth reading because its premise was wrong rather
than merely outdated. The enum error it quotes is real and reproduces, but
Kubernetes build infrastructure is not selected through `runtime` at all; it is
`infrastructure: type: KubernetesDirect`, and that is how an IaCM stage reaches
a cluster whose API server is private.

## Start here

`SETUP.md`. Order matters: the stable DNS name gets decided first, because
everything else hardcodes it.

Budget 30–60 minutes for the first run, and know what a PAT does and does not
get you. It gets you one thing now: `harness/create-iacm-workspace.sh` creates
the IaCM workspace over the API, so that part is repeatable. Everything else is
still by hand. The Terraform in here creates the *database*; it does not create
the Harness objects the pipeline references. Those are the middle steps of
`SETUP.md`: three connectors, a secret, a DB Schema, a DB Instance, and the
placeholder substitution in the pipeline YAML. You also need a cluster with a
delegate inside it, and a cluster admin to apply
`terraform/bootstrap/provisioner-rbac.yaml` once.

So this is still a repo you follow, not a repo you point a token at. The token
just saves you one form.

## License

Apache-2.0. See `LICENSE`.
