###############################################################################
# The idle reaper.
#
# The destroy stage handles the normal case. This handles every other case:
# a cancelled pipeline, a delegate that died mid-run, someone who hit stop
# after the apply. Those leave a database running, and a database that
# outlives its pipeline is the shared staging problem growing back.
#
# Because the database is stateless, "shut it down" is just scaling the
# Deployment to zero. The Service and its DNS name survive, so the JDBC
# connector never breaks — it points at something that will answer again as
# soon as the next run scales it back up. There is no data to preserve and
# no volume to rebind.
#
# Scale to zero rather than delete: deleting the namespace would take the
# Service with it, and the next provision would race to recreate the DNS
# name. Zero replicas frees the compute, which is the part that costs money.
###############################################################################

resource "kubernetes_service_account" "reaper" {
  metadata {
    name      = "ephemeral-db-reaper"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }
}

# Namespace-scoped Role, not a ClusterRole. The reaper can scale deployments
# in this one namespace and nothing else.
resource "kubernetes_role" "reaper" {
  metadata {
    name      = "ephemeral-db-reaper"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "deployments/scale"]
    verbs      = ["get", "list", "patch", "update"]
  }
}

resource "kubernetes_role_binding" "reaper" {
  metadata {
    name      = "ephemeral-db-reaper"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.reaper.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.reaper.metadata[0].name
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "reaper" {
  metadata {
    name      = "ephemeral-db-reaper"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }

  spec {
    schedule                      = var.reaper_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3

    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.reaper.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name  = "reaper"
              image = var.reaper_image

              env {
                name  = "IDLE_TTL_MINUTES"
                value = tostring(var.idle_ttl_minutes)
              }
              env {
                name  = "TARGET_DEPLOYMENT"
                value = kubernetes_deployment.postgres.metadata[0].name
              }
              env {
                name = "NAMESPACE"
                value_from {
                  field_ref { field_path = "metadata.namespace" }
                }
              }

              command = ["/bin/sh", "-c"]
              args = [<<-SCRIPT
                set -eu

                REPLICAS=$(kubectl get deployment "$TARGET_DEPLOYMENT" \
                  -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

                if [ "$REPLICAS" = "0" ]; then
                  echo "Already scaled to zero. Nothing to do."
                  exit 0
                fi

                LAST_USED=$(kubectl get deployment "$TARGET_DEPLOYMENT" \
                  -n "$NAMESPACE" \
                  -o jsonpath='{.metadata.annotations.harness\.io/last-used}')

                if [ -z "$LAST_USED" ]; then
                  echo "No last-used annotation. Leaving it alone rather than"
                  echo "guessing — an unannotated database may be mid-provision."
                  exit 0
                fi

                # GNU date (bitnami/kubectl) and BusyBox date (alpine) take
                # different flags for parsing. Try GNU first, fall back.
                LAST_EPOCH=$(date -d "$LAST_USED" +%s 2>/dev/null \
                  || date -D '%Y-%m-%dT%H:%M:%SZ' -d "$LAST_USED" +%s 2>/dev/null \
                  || echo 0)
                NOW_EPOCH=$(date +%s)

                if [ "$LAST_EPOCH" = "0" ]; then
                  echo "Could not parse last-used value '$LAST_USED'. Leaving it alone."
                  exit 0
                fi

                IDLE_SECONDS=$(( NOW_EPOCH - LAST_EPOCH ))
                TTL_SECONDS=$(( IDLE_TTL_MINUTES * 60 ))

                echo "Idle for $${IDLE_SECONDS}s, threshold $${TTL_SECONDS}s."

                if [ "$IDLE_SECONDS" -gt "$TTL_SECONDS" ]; then
                  echo "Scaling $TARGET_DEPLOYMENT to zero."
                  kubectl scale deployment "$TARGET_DEPLOYMENT" \
                    -n "$NAMESPACE" --replicas=0
                else
                  echo "Still within TTL. Leaving it running."
                fi
                SCRIPT
              ]

              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { cpu = "100m", memory = "128Mi" }
              }
            }
          }
        }
      }
    }
  }
}
