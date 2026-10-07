###############################################################################
# Ephemeral CI database — cloud agnostic.
#
# Nothing in this file is specific to AKS, EKS, or GKE. It talks to the
# Kubernetes API and nothing else, so it runs unchanged on any conformant
# cluster. The reader supplies the cluster and the delegate; this supplies
# the disposable database.
#
# Two design choices worth stating up front:
#
#   1. The database is STATELESS. emptyDir, no PVC, no persistent claim to
#      rebind. That is what makes the pod freely replaceable and removes the
#      "which IP is it this time" problem entirely — consumers address the
#      Service name, which never changes.
#
#   2. The password is a FIXED Harness secret, not generated per run. The
#      database sits on an internal ClusterIP with no ingress and lives for
#      minutes. A rotating credential would buy little and cost an ordering
#      dependency between the provision stage and the migrate stage.
###############################################################################

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

###############################################################################
# Three ways to authenticate. They are listed in the order this repo PREFERS
# them, which is the reverse of the order the provider RESOLVES them — see the
# warning at the bottom, where an accidentally-discovered kubeconfig beats the
# explicit token. Only the first is used by the configuration this repo ships.
#
#   1. IN-CLUSTER CREDENTIALS — the primary path. Leave kube_config_path and
#      kube_config_context empty and set nothing else. The provider reads the
#      projected ServiceAccount token at
#      /var/run/secrets/kubernetes.io/serviceaccount/ and the in-cluster API
#      address from KUBERNETES_SERVICE_HOST.
#
#      This is also the path the IaCM stages take, which is not obvious.
#      Kubernetes build infrastructure is selected through the stage's
#      'infrastructure' block, not through 'runtime' — 'infrastructure: type:
#      KubernetesDirect' runs the IaCM Terraform plugin in a build POD in the
#      target cluster with a mounted ServiceAccount token, which is exactly the
#      identity this block expects. Nothing here needs to change for IaCM, and
#      no KUBE_* variables are needed.
#
#      Proven: terraform 1.5.7 in a pod in harness-builds as ServiceAccount
#      'default', no kubeconfig, this file unchanged — two full applies and two
#      full destroys, 40 resource operations, zero Forbidden errors.
#
#   2. KUBE_HOST + KUBE_CLUSTER_CA_CERT_DATA + KUBE_TOKEN, with
#      kube_config_path still empty. This is for the Docker and Cloud IaCM
#      runtimes, which run the plugin outside the cluster: there is no pod, so
#      there is no mounted token, so the credentials have to arrive as
#      environment variables. The encodings are not guessable:
#
#        KUBE_HOST                   full URI including the scheme, e.g.
#                                    https://1.2.3.4:6443
#        KUBE_CLUSTER_CA_CERT_DATA   RAW PEM, including the
#                                    -----BEGIN CERTIFICATE----- lines. NOT
#                                    base64, despite the _DATA suffix.
#        KUBE_TOKEN                  the raw JWT
#
#      Base64-encode the CA and the failure reads like a corrupt certificate
#      rather than a wrong encoding:
#
#        Error: Failed to configure client: unable to load root certificates:
#        unable to parse bytes as PEM block
#
#   3. kube_config_path (and optionally kube_config_context) for a local apply
#      against a kubeconfig. Convenient for development; not what either IaCM
#      path uses.
#
# WARNING, and this one is load-bearing. Setting kube_config_path to "" makes
# config_path null below, and a null config_path ACTIVATES the provider's own
# environment-variable default: it then reads KUBE_CONFIG_PATH and
# KUBE_CONFIG_PATHS. A kubeconfig discovered that way SILENTLY WINS over
# KUBE_TOKEN. Proven with KUBE_CONFIG_PATH set alongside a deliberately invalid
# KUBE_TOKEN: the run printed
#
#   No changes. Your infrastructure matches the configuration.
#
# against the wrong cluster, with no warning anywhere.
#
# This hazard is PATH-INDEPENDENT. Paths 1 and 2 both leave kube_config_path
# empty, so both activate that default — path 1, the primary one, included. On
# path 1 a stray KUBE_CONFIG_PATH beats the pod's own projected ServiceAccount
# token exactly as it beats KUBE_TOKEN on path 2. So KUBE_CONFIG_PATH and
# KUBE_CONFIG_PATHS must be unset on both. Only path 3, which sets
# kube_config_path to a non-empty value, is immune — there config_path is
# explicit and no default applies.
#
# Note the provider does NOT read KUBECONFIG, so unsetting only KUBECONFIG —
# the obvious move — protects nothing.
###############################################################################
provider "kubernetes" {
  config_path    = var.kube_config_path != "" ? var.kube_config_path : null
  config_context = var.kube_config_context != "" ? var.kube_config_context : null
}

resource "kubernetes_namespace" "ephemeral" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "harness-iacm"
      "harness.io/lifecycle"         = "ephemeral"
    }
  }
}

resource "kubernetes_secret" "db" {
  metadata {
    name      = "ephemeral-db-credentials"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }
  data = {
    POSTGRES_DB       = var.db_name
    POSTGRES_USER     = var.db_user
    POSTGRES_PASSWORD = var.db_password
  }
}

resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "ephemeral-db"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
    labels    = { app = "ephemeral-db" }
    annotations = {
      # The idle reaper reads this. Refreshed by the pipeline on every run.
      #
      # Falling back to timestamp() matters more than it looks. The reaper
      # skips any deployment whose annotation it cannot parse, on the reasoning
      # that an unannotated database may be mid-provision — so a database born
      # with an empty annotation is never reaped at all. The wake step is what
      # writes the first real value, which leaves a window between this apply
      # and that step where an aborted run would leak the database
      # permanently. Provision time is a truthful "last used" for a database
      # nothing has touched yet, and it closes the window.
      #
      # timestamp() would normally cause drift on every plan; ignore_changes
      # below covers this key, so it is only ever evaluated at create time.
      "harness.io/last-used" = var.last_used_timestamp != "" ? var.last_used_timestamp : timestamp()
    }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "ephemeral-db" } }

    # Recreate, not the default RollingUpdate. One replica on emptyDir means
    # there is nothing to keep available and nothing to preserve, while a
    # rolling update briefly runs two pods — and the Service can route to the
    # new, empty one while the old one still holds the migrated schema. That
    # produces connection-level flakiness that looks like a network problem.
    # Tear the old pod down first; a fresh empty database is the goal anyway.
    strategy {
      type = "Recreate"
    }

    template {
      metadata { labels = { app = "ephemeral-db" } }
      spec {
        container {
          name = "postgres"
          # Pin to the version production runs. Testing a migration against a
          # different major version tests the wrong thing.
          image = "postgres:${var.postgres_version}"

          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }

          port { container_port = 5432 }

          # emptyDir, deliberately. Nothing here should outlive the pod, and
          # a stateless pod can be scaled to zero and back without ceremony.
          volume_mount {
            name       = "pgdata"
            mount_path = "/var/lib/postgresql/data"
          }

          readiness_probe {
            # Probe over TCP (-h 127.0.0.1), not the Unix socket. During initdb
            # the entrypoint runs a temporary server that listens on the socket
            # only, so a socket probe reports ready while the database is still
            # bootstrapping and about to be restarted. Forcing TCP means this
            # probe passes only once the real server is accepting connections.
            exec {
              command = [
                "pg_isready",
                "-h", "127.0.0.1",
                "-p", "5432",
                "-U", var.db_user,
                "-d", var.db_name,
              ]
            }
            initial_delay_seconds = 5
            period_seconds        = 3
            failure_threshold     = 20
          }

          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
        }

        volume {
          name = "pgdata"
          empty_dir {}
        }
      }
    }
  }

  # Both of these fields are owned by something other than Terraform once the
  # deployment exists, so Terraform has to stop competing for them:
  #
  #   replicas          - the idle reaper scales this to zero, and stage 2
  #                       scales it back up.
  #   harness.io/last-used - stage 2 stamps this on every run with kubectl
  #                       annotate. Without ignore_changes, every plan shows
  #                       drift on the annotation and every apply resets it to
  #                       var.last_used_timestamp (empty by default), which
  #                       makes the reaper treat a live database as
  #                       unannotated.
  lifecycle {
    ignore_changes = [
      spec[0].replicas,
      metadata[0].annotations["harness.io/last-used"],
    ]
  }
}

# The stable endpoint. This name is what the Harness JDBC connector points at.
# It is the only thing here that must not change between runs.
resource "kubernetes_service" "postgres" {
  metadata {
    name      = var.service_name
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }
  spec {
    selector = { app = "ephemeral-db" }
    port {
      port        = 5432
      target_port = 5432
    }
    type = "ClusterIP"
  }
}
