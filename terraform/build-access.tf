###############################################################################
# Access for the pipeline's build pods.
#
# Stage 2's first step runs kubectl against the database's namespace: it reads
# the replica count, scales the deployment back up if the reaper got there
# first, and stamps the harness.io/last-used heartbeat.
#
# That step runs in a build pod in the Harness build namespace, under that
# namespace's ServiceAccount. It is NOT the delegate's ServiceAccount and it is
# NOT the reaper's, so neither of those bindings helps it. Without the Role
# below, the wake step fails with "deployments.apps is forbidden".
#
# Scoped as tightly as the reaper's: one namespace, one resource type, and only
# the verbs the wake step actually issues.
###############################################################################

resource "kubernetes_role" "build_db_access" {
  metadata {
    name      = "ephemeral-db-build-access"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }

  # get          - read .spec.replicas and the last-used annotation
  # patch        - kubectl annotate
  # list + watch - kubectl rollout status opens a watch, and a watch on a named
  #                resource still requires list on the collection. Without both,
  #                the wake step burns its full --timeout and exits 1 with
  #                "cannot list resource deployments".
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "patch"]
  }

  # update - kubectl scale writes through the scale subresource
  rule {
    api_groups = ["apps"]
    resources  = ["deployments/scale"]
    verbs      = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "build_db_access" {
  metadata {
    name      = "ephemeral-db-build-access"
    namespace = kubernetes_namespace.ephemeral.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.build_db_access.metadata[0].name
  }

  # The subject lives in the build namespace; the binding lives in the database
  # namespace. That is what grants cross-namespace access without a ClusterRole.
  subject {
    kind      = "ServiceAccount"
    name      = var.build_service_account
    namespace = var.build_namespace
  }
}
