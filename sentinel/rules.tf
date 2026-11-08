locals {
  detections = {
    for f in fileset("${path.module}/../detections", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../detections/${f}"))
  }

  # Sentinel-YAML durations -> ISO 8601. lookup() without default fails the plan on an unknown value.
  iso_duration     = { "5m" = "PT5M", "15m" = "PT15M", "1h" = "PT1H", "5h" = "PT5H", "1d" = "P1D", "14d" = "P14D" }
  trigger_operator = { gt = "GreaterThan", lt = "LessThan", eq = "Equal", ne = "NotEqual" }
}

resource "azurerm_sentinel_alert_rule_scheduled" "rule" {
  for_each = local.detections

  name                       = each.value.id
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.this.workspace_id
  display_name               = each.value.name
  description                = trimspace(each.value.description)
  severity                   = each.value.severity
  enabled                    = true
  query                      = each.value.query
  query_frequency            = lookup(local.iso_duration, each.value.queryFrequency)
  query_period               = lookup(local.iso_duration, each.value.queryPeriod)
  trigger_operator           = lookup(local.trigger_operator, each.value.triggerOperator)
  trigger_threshold          = each.value.triggerThreshold
  tactics                    = each.value.tactics
  techniques                 = distinct([for t in each.value.relevantTechniques : split(".", t)[0]])

  # One alert per result row: needed for per-row dynamic severity (SLZ-003).
  event_grouping {
    aggregation_method = "AlertPerResult"
  }

  dynamic "alert_details_override" {
    for_each = try(each.value.alertDetailsOverride.alertSeverityColumnName, null) == null ? [] : [each.value.alertDetailsOverride]
    content {
      severity_column_name = alert_details_override.value.alertSeverityColumnName
    }
  }

  dynamic "entity_mapping" {
    for_each = try(each.value.entityMappings, [])
    content {
      entity_type = entity_mapping.value.entityType
      dynamic "field_mapping" {
        for_each = entity_mapping.value.fieldMappings
        content {
          identifier  = field_mapping.value.identifier
          column_name = field_mapping.value.columnName
        }
      }
    }
  }

  # Alerts from the same rule with the same entities within 5 h group into one incident.
  incident {
    create_incident_enabled = true
    grouping {
      enabled                 = true
      lookback_duration       = "PT5H"
      reopen_closed_incidents = false
      entity_matching_method  = "AllEntities"
    }
  }

  depends_on = [time_sleep.function_indexed, azurerm_log_analytics_saved_search.known_principals]
}
