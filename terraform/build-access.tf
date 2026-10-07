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
#
# THIS FILE IS IN PLAY ON EVERY PATH. Stage 2 is always a KubernetesDirect step
# group — that does not change when stages 1 and 3 switch between IACM and
# Custom, or when the IaCM runtime switches between Kubernetes and Docker/Cloud.
# So the wake step is always an in-cluster build pod and this RoleBinding is
# always the grant governing it. The Docker/Cloud fallback changes which
# identity applies the Terraform; it does not change stage 2 at all.
#
# A caveat about redundancy, not about paths: `terraform/bootstrap/
# provisioner-rbac.yaml` binds this same subject — `<build_namespace>:default`
# — to ClusterRole ephemeral-db-provisioner, which already carries deployments
# get/list/watch/patch and deployments/scale get/update/patch CLUSTER-WIDE. So
# for the wake step specifically this namespaced Role is a subset of a grant the
# subject already holds, and is defence-in-depth rather than the thing standing
# between the wake step and a Forbidden. It earns its place by being the grant
# that survives: narrow the bootstrap ClusterRole, or point the pipeline at a
# build ServiceAccount the bootstrap file does not bind, and this is what is
# left. Keep it.
#
# Consequence when chasing a Forbidden on the wake step: because the subject
# holds both grants, a Forbidden here almost never means a missing verb. It
# means the SUBJECT is wrong — the build namespace in the pipeline
# (<<HARNESS_BUILD_NAMESPACE>>) is not the namespace the bootstrap file and
# var.build_namespace name. Read the ServiceAccount in the error message before
# editing any rule.
#
# One more thing to know before editing the subject below: nothing in the
# pipeline sets build_service_account — on the IaCM path the pipeline passes no
# Terraform variables at all, and the workspace is the only source — so
# var.build_service_account falls back to "default". Only "default" is proven,
# because it is the only subject the bootstrap ClusterRoleBinding grants. This
# variable selects the subject of the RoleBinding below and nothing else; it
# does not reach the bootstrap ClusterRoleBinding, which is a static YAML file.
# Naming a different ServiceAccount here therefore still gets the wake step its
# namespaced grant, but that ServiceAccount loses the cluster-wide one — so if
# you have also narrowed anything, bind it in bootstrap too.
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
