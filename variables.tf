variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "synapse_version" {
  type        = string
  default     = "v1.164.1"
  description = "Tag of the ghcr.io/element-hq/synapse image, such as \"v1.164.1\"."

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.synapse_version))
    error_message = "synapse_version must be an image tag, such as \"v1.164.1\"."
  }
}

variable "server_name" {
  type        = string
  description = "The domain in every user ID and room alias, such as \"example.com\" for @alice:example.com. It can never change once Synapse has started with it."

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$", var.server_name))
    error_message = "server_name must be a host name, optionally with a port, such as \"example.com\" or \"matrix.example.com:8448\"."
  }
}

variable "public_baseurl" {
  type        = string
  description = "URL clients reach Synapse at through your reverse proxy, such as \"https://matrix.example.com/\"."

  validation {
    condition     = can(regex("^https?://[A-Za-z0-9.:\\[\\]-]+(/[^\\s\"]*)?$", var.public_baseurl))
    error_message = "public_baseurl must be an http or https URL, such as \"https://matrix.example.com/\"."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address Synapse listens on. The default keeps it to the host itself, for a reverse proxy in front."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }
}

variable "listen_port" {
  type        = number
  default     = 8008
  description = "Port Synapse serves the client and federation APIs on, in plain HTTP."

  validation {
    condition     = var.listen_port >= 1 && var.listen_port <= 65535 && floor(var.listen_port) == var.listen_port
    error_message = "listen_port must be a port number from 1 to 65535."
  }
}

variable "postgres" {
  type = object({
    host     = optional(string, "127.0.0.1")
    port     = optional(number, 5432)
    database = optional(string, "synapse")
    username = optional(string, "synapse")
  })
  default     = null
  description = "PostgreSQL to keep Synapse's data in, such as { host = \"db1\" }. The role and database must exist, the database with C collation. When null, Synapse uses SQLite in /var/lib/matrix-synapse, which is for trials only."

  validation {
    condition     = var.postgres == null || alltrue([for k, v in coalesce(var.postgres, {}) : can(regex("^[A-Za-z0-9_.:-]+$", tostring(v)))])
    error_message = "postgres host, database and username may use letters, digits and . _ - :."
  }
}

variable "postgres_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password of the postgres username. Needed with postgres. Pass it at run time with -var or TF_VAR_postgres_password; it never reaches state or the plan."

  validation {
    condition     = var.postgres == null || length(coalesce(var.postgres_password, "")) > 0
    error_message = "postgres needs postgres_password."
  }

  validation {
    condition     = !strcontains(coalesce(var.postgres_password, "-"), "\n")
    error_message = "postgres_password must be on one line."
  }
}

variable "admin_user" {
  type        = string
  default     = null
  description = "Localpart of an admin user to create, such as \"admin\" for @admin:SERVER_NAME. When null, no user is created."

  validation {
    condition     = var.admin_user == null || can(regex("^[a-z0-9._=/+-]+$", coalesce(var.admin_user, "-")))
    error_message = "admin_user may use lowercase letters, digits and . _ = / + -."
  }
}

variable "admin_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password the admin user is created with. Needed with admin_user. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  validation {
    condition     = var.admin_user == null || (length(coalesce(var.admin_password, "")) >= 8 && !strcontains(coalesce(var.admin_password, "-"), "\n"))
    error_message = "admin_user needs an admin_password of at least 8 characters, on one line."
  }
}

variable "settings" {
  type        = any
  default     = {}
  description = "Extra homeserver.yaml settings, merged over the circuit's at the top level, such as { enable_registration = true, registration_requires_token = true }."

  validation {
    condition     = length(setintersection(keys(var.settings), ["server_name", "public_baseurl", "listeners", "database", "signing_key_path", "media_store_path", "registration_shared_secret", "registration_shared_secret_path", "macaroon_secret_key", "macaroon_secret_key_path", "form_secret", "form_secret_path"])) == 0
    error_message = "settings can't set server_name, public_baseurl, listeners, database, the key and media paths or the secrets. Use the circuit's inputs for those; the secrets are generated on the host."
  }
}
