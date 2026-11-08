locals {
  # Built from names on purpose: data.azurerm_log_analytics_workspace reads shared keys on every
  # refresh, which would trigger SLZ-003 on the operator's own apply.
  workspace_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.workspace_rg}/providers/Microsoft.OperationalInsights/workspaces/${var.workspace_name}"
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  workspace_id                 = local.workspace_id
  customer_managed_key_enabled = false
}

# Same text the emulator tests use (functions/KnownPrincipals.kql), so rule queries are identical (D4).
resource "azurerm_log_analytics_saved_search" "known_principals" {
  name                       = "KnownPrincipals"
  log_analytics_workspace_id = local.workspace_id
  category                   = "SLZ detections"
  display_name               = "KnownPrincipals"
  function_alias             = "KnownPrincipals"
  query                      = file("${path.module}/../functions/KnownPrincipals.kql")
}

# Sentinel validates each rule query at create time; a brand-new workspace function needs a moment
# before the query engine resolves it.
resource "time_sleep" "function_indexed" {
  create_duration = "90s"

  triggers = {
    function = sha1(azurerm_log_analytics_saved_search.known_principals.query)
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}
