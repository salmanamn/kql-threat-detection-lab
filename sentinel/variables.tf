variable "subscription_id" {
  description = "Lab subscription (terraform.tfvars, gitignored)."
  type        = string
}

variable "workspace_rg" {
  description = "Resource group of the Project 1 platform workspace."
  type        = string
  default     = "rg-slz-platform"
}

variable "workspace_name" {
  description = "Project 1 platform workspace (S2-4)."
  type        = string
  default     = "log-slz-platform"
}
