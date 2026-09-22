# ephemeral-db-harness

A database that did not exist a minute ago, proves your migration, and is gone before the pipeline exits.

Harness IaCM provisions it. Harness Database DevOps migrates it. IaCM destroys it — including when the migration fails. A CronJob catches the runs that never reach teardown at all.

```
Stage 1 (IaCM)          Stage 2 (DB DevOps)        Stage 3 (IaCM)
init/plan/apply    ->   clone, wake, seed,    ->   init/plan-destroy/destroy
                        apply, verify              when: pipelineStatus: All

            CronJob: scales to zero after 1h unused
```

## Cloud agnostic

The Terraform talks to the Kubernetes API and nothing else. AKS, EKS, GKE, self-managed — same module, same variables. You bring the cluster and a Harness delegate running inside it.

## Layout

```
terraform/
  main.tf          Stateless Postgres: fresh pod every run, constant Service DNS name.
  reaper.tf        CronJob + scoped RBAC. Scales to zero after idle_ttl_minutes.
  build-access.tf  Lets the pipeline's build pods scale and annotate the database.
  variables.tf     No cloud credentials. Only db_password is secret.
  outputs.tf       jdbc_url and friends, surfaced on the IaCM Resources tab.
  jdbc-connector.tf.example
                   Optional: have IaCM own the JDBC connector instead of
                   creating it by hand. Drop the .example suffix to use it.
  backend-kubernetes.tf.example
                   Remote state in a Kubernetes Secret. The provision stage
                   copies this into place; without it the destroy stage plans
                   against nothing and leaks the database while going green.
  bootstrap/
    provisioner-rbac.yaml
                   The one-time grant a cluster admin applies before the first
                   run. Everything else here is applied by the pipeline; this
                   is what lets the pipeline apply anything.
harness/
  pipeline-ephemeral-db-ci.yaml
                   The three-stage pipeline. Provision, migrate, destroy.
  iacm-stages.yaml.example
                   Stages 1 and 3 as IaCM stages instead. Better when your
                   cluster endpoint is reachable from the IaCM runtime; see the
                   header for when it is not.
sql/
  migrations/      V1 baseline + V2 (the migration under test).
  db.changelog-master.xml
                   Liquibase changelog over the same migration files, so both
                   tools apply byte-identical SQL.
  seed/            Production-shaped rows, including edge cases.
  checks/          Six assertions that gate the pipeline.
  broken/          Passes on an empty DB, fails on a seeded one.
SETUP.md           Step-by-step wiring guide. Start here.
BLOG.md            The written version of the argument.
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

Being precise about this, because "it looks right" is how the `NOT NULL` bug at the top of this README ships in the first place.

All three stages run green on app.harness.io against minikube on colima, from an
empty cluster to a destroyed namespace, on both migration tools:

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

**Read `ISSUES.md` before debugging anything.** Getting to those green runs
turned up sixteen problems, and in four cases the symptom already had a
troubleshooting entry in SETUP.md that named the wrong cause. Two are still
open by choice rather than fixed: Liquibase runs through the CLI instead of
`DBSchemaApply` (issue 13, a platform bug), and provisioning runs as a Custom
stage instead of IaCM (issue 6, because IaCM cannot reach a private cluster).

## Start here

`SETUP.md`. Order matters: the stable DNS name gets decided first, because
everything else hardcodes it.

Budget 30–60 minutes for the first run, and know what a PAT does and does not
get you. The Terraform in here creates the *database*; it does not create the
Harness objects the pipeline references. Those are steps 3 to 6 of `SETUP.md`,
done by hand: three connectors, a secret, a DB Schema, a DB Instance, and the
placeholder substitution in the pipeline YAML. You also need a cluster with a
delegate inside it, and a cluster admin to apply
`terraform/bootstrap/provisioner-rbac.yaml` once.

So this is a repo you follow, not a repo you point a token at.

## License

Apache-2.0. See `LICENSE`.
