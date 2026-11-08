output "workspace_id" {
  value = local.workspace_id
}

output "rules" {
  value = { for k, r in azurerm_sentinel_alert_rule_scheduled.rule : k => r.display_name }
}
