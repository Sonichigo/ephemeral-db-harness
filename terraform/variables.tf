###############################################################################
# Nothing here is cloud specific. Same variables on AKS, EKS, GKE, or a
# self-managed cluster.
###############################################################################

variable "namespace" {
  description = "Namespace holding the ephemeral database."
  type        = string
  default     = "dbops-ci"
}

variable "service_name" {
  description = <<-DESC
    Kubernetes Service name. THIS MUST STAY CONSTANT.

    DB Instances require a fixed connector — the connector reference cannot be
    a pipeline expression. This design satisfies that by keeping the address
    constant: the JDBC connector is pinned to this DNS name once, and the pod
    behind it is replaced on every run.

    The alternative is to let IaCM own the connector itself, so its identifier
    stays fixed while its URL changes per run. See jdbc-connector.tf.example.
  DESC
  type        = string
  default     = "ephemeral-db"
}

variable "postgres_version" {
  description = "Postgres image tag. Match production exactly."
  type        = string
  default     = "16.4"
}

variable "db_name" {
  type    = string
  default = "app_test"
}

variable "db_user" {
  type    = string
  default = "ci"
}

variable "db_password" {
  description = <<-DESC
    Fixed password, supplied from a Harness secret as an IaCM secret variable.

    Deliberately not generated per run. The JDBC connector needs a fixed
    credential, and the database is on an internal ClusterIP with no ingress
    for a handful of minutes. Rotating it would add an ordering dependency
    between the provision and migrate stages in exchange for very little.
  DESC
  type        = string
  sensitive   = true
}

variable "last_used_timestamp" {
  description = <<-DESC
    RFC3339 timestamp written to the deployment annotation the idle reaper
    reads. Stage 2's wake step overwrites it on every run with kubectl
    annotate, so this only sets the value the database is BORN with.

    Leave it empty and main.tf substitutes timestamp() — the provision time.
    Do not change that to a literal empty annotation: the reaper deliberately
    skips deployments it cannot read a timestamp from, so a database created
    with an empty annotation is never reaped. A run cancelled between the
    apply and the wake step would then leak that database forever, which is
    exactly the case the reaper exists to cover.
  DESC
  type        = string
  default     = ""
}

variable "idle_ttl_minutes" {
  description = "Scale the database to zero after this many minutes unused."
  type        = number
  default     = 60
}

variable "reaper_schedule" {
  description = "Cron schedule for the idle check. Every 10 minutes by default."
  type        = string
  default     = "*/10 * * * *"
}

variable "reaper_image" {
  description = <<-DESC
    Image with kubectl on PATH.

    Not bitnami/kubectl: Bitnami retired its free Docker Hub catalog, so those
    tags no longer resolve at all. A reaper that cannot pull fails quietly —
    the CronJob object still looks healthy while its Job sits wedged, and
    because concurrency_policy is Forbid, one stuck Job suppresses every later
    tick. Nothing gets scaled down and nothing turns red.

    Whatever you substitute, note that the reaper's date parsing handles both
    GNU date and BusyBox date, so Alpine-based images are fine.
  DESC
  type        = string
  default     = "alpine/k8s:1.30.0"
}

variable "build_namespace" {
  description = <<-DESC
    Namespace the pipeline's build pods run in, matching the step group's
    stepGroupInfra.spec.namespace. Stage 2's wake step needs permission to
    scale and annotate the database deployment from there, which build-access.tf
    grants. Same value as <<HARNESS_BUILD_NAMESPACE>> in the pipeline.

    Deliberately NOT the delegate's namespace. The delegate manifest binds
    cluster-admin to that namespace's default ServiceAccount, so running build
    pods there makes them cluster-admin and makes build-access.tf a no-op —
    every permission it grants is already held. That hides RBAC mistakes until
    someone tightens the cluster, at which point the wake step starts failing
    and nothing in the Terraform changed. Give build pods their own namespace
    and let this file be the only thing granting them access.
  DESC
  type        = string
  default     = "harness-builds"
}

variable "build_service_account" {
  description = <<-DESC
    ServiceAccount the build pods run as. Leave as "default" unless the
    Kubernetes connector's step group is configured with a specific
    serviceAccountName.
  DESC
  type        = string
  default     = "default"
}

variable "kube_config_path" {
  description = <<-DESC
    Leave empty to use in-cluster credentials — the normal case when the
    IaCM stage runs on a delegate inside the target cluster. Set this when
    the delegate is outside the cluster or when running locally.
  DESC
  type        = string
  default     = ""
}

variable "kube_config_context" {
  type    = string
  default = ""
}
