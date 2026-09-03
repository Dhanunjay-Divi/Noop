variable "project_id" {
  description = "Dedicated Google Cloud project ID for synthetic staging."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid Google Cloud project ID."
  }
}

variable "region" {
  description = "Single staging region. Mumbai is the India-first default."
  type        = string
  default     = "asia-south1"

  validation {
    condition     = contains(["asia-south1", "asia-south2"], var.region)
    error_message = "region must be asia-south1 (Mumbai) or asia-south2 (Delhi)."
  }
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging"], var.environment)
    error_message = "This stack is intentionally limited to synthetic staging."
  }
}

variable "raw_retention_days" {
  description = "Age at which staging raw chunks are automatically deleted."
  type        = number
  default     = 30

  validation {
    condition = (
      floor(var.raw_retention_days) == var.raw_retention_days
      && var.raw_retention_days >= 1
      && var.raw_retention_days <= 30
    )
    error_message = "Synthetic staging raw retention must be 1 through 30 days."
  }
}

variable "raw_bucket_name" {
  description = "Optional globally unique override for the raw-chunk bucket."
  type        = string
  default     = null

  validation {
    condition = (
      var.raw_bucket_name == null
      || can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.raw_bucket_name))
    )
    error_message = "raw_bucket_name must be a valid Cloud Storage bucket name."
  }
}

variable "enable_managed_database" {
  description = "Create the synthetic-only staging Cloud SQL instance."
  type        = bool
  default     = false
}

variable "database_tier" {
  description = "Small staging Cloud SQL tier. Production sizing is a separate decision."
  type        = string
  default     = "db-f1-micro"

  validation {
    condition     = contains(["db-f1-micro", "db-g1-small"], var.database_tier)
    error_message = "database_tier is limited to a shared-core staging tier."
  }
}

variable "runtime_image" {
  description = "Digest-pinned API image. Null creates no Cloud Run workloads."
  type        = string
  default     = null

  validation {
    condition = (
      var.runtime_image == null
      || can(regex(
        "^asia-south[12]-docker\\.pkg\\.dev/[a-z][a-z0-9-]{4,28}[a-z0-9]/[a-z0-9._-]+/[a-z0-9._-]+@sha256:[0-9a-f]{64}$",
        var.runtime_image,
      ))
    )
    error_message = "runtime_image must be an asia-south1/2 Artifact Registry sha256 digest URI."
  }
}

variable "enable_private_api" {
  description = "Create the IAM-protected, internal-ingress staging API after migrations pass."
  type        = bool
  default     = false

  validation {
    condition = (
      !var.enable_private_api
      || (var.enable_managed_database && var.runtime_image != null)
    )
    error_message = "enable_private_api requires the managed database and a digest-pinned runtime_image."
  }
}
