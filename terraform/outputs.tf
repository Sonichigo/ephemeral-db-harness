# These surface on the IaCM Resources tab after apply.

output "jdbc_url" {
  description = "Fixed JDBC URL. Must match the Harness JDBC connector exactly."
  value       = "jdbc:postgresql://${kubernetes_service.postgres.metadata[0].name}.${kubernetes_namespace.ephemeral.metadata[0].name}.svc.cluster.local:5432/${var.db_name}"
}

output "db_host" {
  description = "Stable Service DNS name. Does not change between runs."
  value       = "${kubernetes_service.postgres.metadata[0].name}.${kubernetes_namespace.ephemeral.metadata[0].name}.svc.cluster.local"
}

output "db_user" {
  value = var.db_user
}

output "namespace" {
  value = kubernetes_namespace.ephemeral.metadata[0].name
}

output "idle_shutdown_after" {
  description = "Minutes of disuse before the reaper scales the database to zero."
  value       = var.idle_ttl_minutes
}
