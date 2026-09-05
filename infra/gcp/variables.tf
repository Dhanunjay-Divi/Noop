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

variable "enable_managed_identity" {
  description = "Enable synthetic-staging Firebase apps and Identity Platform phone OTP."
  type        = bool
  default     = false
}

variable "managed_apple_bundle_id" {
  description = "Exact iOS bundle identifier registered for synthetic NOOP+ staging."
  type        = string
  default     = "com.noopapp.noop"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", var.managed_apple_bundle_id))
    error_message = "managed_apple_bundle_id must be a reverse-DNS bundle identifier."
  }
}

variable "managed_android_package_name" {
  description = "Exact signed Android staging package registered for synthetic NOOP+ staging."
  type        = string
  default     = "com.noop.whoop.staging"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$", var.managed_android_package_name))
    error_message = "managed_android_package_name must be a valid Android package name."
  }
}

variable "managed_android_sha1_fingerprints" {
  description = "Release-signing SHA-1 certificate fingerprints allowed to use the Android Firebase API key."
  type        = list(string)
  default     = []

  validation {
    condition = (
      !var.enable_managed_identity
      || (
        length(var.managed_android_sha1_fingerprints) >= 1
        && length(distinct(var.managed_android_sha1_fingerprints)) == length(var.managed_android_sha1_fingerprints)
        && alltrue([
          for fingerprint in var.managed_android_sha1_fingerprints :
          can(regex("^([A-Fa-f0-9]{40}|([A-Fa-f0-9]{2}:){19}[A-Fa-f0-9]{2})$", fingerprint))
        ])
      )
    )
    error_message = "Managed identity requires at least one unique Android release SHA-1 certificate fingerprint."
  }
}

variable "managed_android_sha256_fingerprints" {
  description = "Release-signing SHA-256 certificate fingerprints registered with Play Integrity."
  type        = list(string)
  default     = []

  validation {
    condition = (
      !var.enable_managed_identity
      || (
        length(var.managed_android_sha256_fingerprints) >= 1
        && length(distinct(var.managed_android_sha256_fingerprints)) == length(var.managed_android_sha256_fingerprints)
        && alltrue([
          for fingerprint in var.managed_android_sha256_fingerprints :
          can(regex("^([A-Fa-f0-9]{64}|([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2})$", fingerprint))
        ])
      )
    )
    error_message = "Managed identity requires at least one unique Android release SHA-256 certificate fingerprint."
  }
}

variable "enable_managed_app_check" {
  description = "Register App Attest and Play Integrity for synthetic managed clients."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_managed_app_check || var.enable_managed_identity
    error_message = "enable_managed_app_check requires enable_managed_identity."
  }
}

variable "managed_auth_app_check_enforcement" {
  description = "Firebase Authentication App Check mode. Public managed ingress requires ENFORCED."
  type        = string
  default     = "UNENFORCED"

  validation {
    condition     = contains(["UNENFORCED", "ENFORCED"], var.managed_auth_app_check_enforcement)
    error_message = "managed_auth_app_check_enforcement must be UNENFORCED or ENFORCED."
  }
}

variable "managed_sms_regions" {
  description = "Explicit ISO country allowlist for staging phone OTP delivery."
  type        = list(string)
  default     = ["IN", "US"]

  validation {
    condition = (
      length(var.managed_sms_regions) >= 1
      && length(var.managed_sms_regions) <= 8
      && length(distinct(var.managed_sms_regions)) == length(var.managed_sms_regions)
      && alltrue([
        for region in var.managed_sms_regions :
        can(regex("^[A-Z]{2}$", region))
      ])
    )
    error_message = "managed_sms_regions must contain 1 through 8 unique uppercase ISO country codes."
  }
}

variable "managed_test_phone_numbers" {
  description = "Untracked synthetic-only E.164 phone numbers mapped to six-digit Firebase test codes."
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    condition = (
      length(var.managed_test_phone_numbers) <= 10
      && alltrue([
        for phone, code in var.managed_test_phone_numbers :
        can(regex("^\\+[1-9][0-9]{7,14}$", phone))
        && can(regex("^[0-9]{6}$", code))
      ])
    )
    error_message = "managed_test_phone_numbers must contain at most 10 E.164 numbers mapped to six-digit codes."
  }
}

variable "enable_managed_runtime" {
  description = "Deploy the IAM-only NOOP+ API, processor, and lifecycle workloads for synthetic staging."
  type        = bool
  default     = false

  validation {
    condition = (
      !var.enable_managed_runtime
      || (
        var.enable_managed_identity
        && var.enable_managed_app_check
        && var.managed_auth_app_check_enforcement == "ENFORCED"
        && var.enable_managed_database
        && var.runtime_image != null
      )
    )
    error_message = "enable_managed_runtime requires enforced managed identity/App Check, Cloud SQL, and a digest-pinned image."
  }
}

variable "enable_public_managed_api" {
  description = "Allow unauthenticated Cloud Run invocation so the managed API can enforce Firebase identity and App Check."
  type        = bool
  default     = false

  validation {
    condition = (
      !var.enable_public_managed_api
      || (
        var.enable_managed_runtime
        && var.enable_managed_identity
        && var.enable_managed_app_check
        && var.managed_auth_app_check_enforcement == "ENFORCED"
        && var.enable_managed_database
        && var.runtime_image != null
      )
    )
    error_message = "enable_public_managed_api requires the managed runtime plus enforced identity/App Check, Cloud SQL, and a digest-pinned image."
  }
}

variable "managed_entitlement_mode" {
  description = "Managed enrollment admission: closed, verified pilot claim, explicit open beta, or pre-provisioned paid accounts."
  type        = string
  default     = "closed"

  validation {
    condition     = contains(["closed", "pilot", "open_beta", "paid"], var.managed_entitlement_mode)
    error_message = "managed_entitlement_mode must be closed, pilot, open_beta, or paid."
  }
}
