locals {
  etc  = "/etc/matrix-synapse"
  data = "/var/lib/matrix-synapse"
  ids  = "/etc/matrix-synapse/ids.env"

  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.listen_address, strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address)
  local_url  = "http://${local.local_host}:${var.listen_port}"

  # Generated on the host by the first apply. Synapse reads each from the
  # file its *_path setting names, so none is in the config, the plan or
  # state. The signing key is Synapse's own: it writes /data/signing.key on
  # its first start.
  secrets = ["registration_shared_secret", "macaroon_secret_key", "form_secret"]

  # The PostgreSQL password isn't here. It reaches Synapse as PGPASSWORD in
  # the container's env file, which libpq reads when the config has none.
  # Picked from a tuple rather than with a conditional, which would turn
  # cp_min and cp_max into strings to match the two branches' types.
  database = [
    {
      name = "sqlite3"
      args = { database = "/data/homeserver.db" }
    },
    {
      name = "psycopg2"
      args = {
        host   = try(var.postgres.host, null)
        port   = try(var.postgres.port, null)
        dbname = try(var.postgres.database, null)
        user   = try(var.postgres.username, null)
        cp_min = 5
        cp_max = 10
      }
    },
  ][var.postgres == null ? 0 : 1]

  # Paths are as the container sees them: /config is /etc/matrix-synapse,
  # read-only, and /data is /var/lib/matrix-synapse.
  homeserver = merge(
    {
      server_name    = var.server_name
      public_baseurl = var.public_baseurl
      listeners = [{
        port           = var.listen_port
        bind_addresses = [var.listen_address]
        type           = "http"
        tls            = false
        # The reverse proxy in front gives the client's address.
        x_forwarded = true
        resources   = [{ names = ["client", "federation"], compress = false }]
      }]
      database                        = local.database
      signing_key_path                = "/data/signing.key"
      media_store_path                = "/data/media_store"
      registration_shared_secret_path = "/config/registration_shared_secret"
      macaroon_secret_key_path        = "/config/macaroon_secret_key"
      form_secret_path                = "/config/form_secret"
      enable_registration             = false
      report_stats                    = false
      # Answers /.well-known/matrix/server with public_baseurl's host on
      # port 443, so other servers find Synapse behind the proxy.
      serve_server_wellknown      = true
      trusted_key_servers         = [{ server_name = "matrix.org" }]
      suppress_key_server_warning = true
    },
    var.settings,
  )

  config = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${yamlencode(local.homeserver)}"
}

circuit "synapse" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Waits for Synapse to come up.
  step "curl" {
    package {
      name = "curl"
    }
  }

  step "group" {
    group {
      name   = "matrix-synapse"
      system = true
    }
  }

  step "user" {
    user {
      name   = "matrix-synapse"
      group  = "matrix-synapse"
      system = true
      shell  = "/usr/sbin/nologin"
    }
  }

  # The config and its secrets belong to root, and Synapse can only read
  # them.
  step "config_dir" {
    directory {
      path  = local.etc
      owner = "root"
      group = "matrix-synapse"
      mode  = "0750"
    }
  }

  # Synapse runs in the container as the host account's IDs, which differ
  # from host to host, so they reach the image's start script from a file
  # of each host's own. The image's default, 991, is taken on some hosts,
  # such as by systemd-resolve on Ubuntu.
  step "ids" {
    command {
      command = "printf 'UID=%s\\nGID=%s\\n' \"$(id -u matrix-synapse)\" \"$(id -g matrix-synapse)\" > ${local.ids}"
      unless  = "[ \"$(cat ${local.ids})\" = \"$(printf 'UID=%s\\nGID=%s' \"$(id -u matrix-synapse)\" \"$(id -g matrix-synapse)\")\" ]"
    }
  }

  # The database, media and signing key. Back this up.
  step "data_dir" {
    directory {
      path  = local.data
      owner = "matrix-synapse"
      group = "matrix-synapse"
      mode  = "0700"
    }
  }

  # 64 letters and digits. A new macaroon_secret_key would sign everyone
  # out, so these are made once and kept.
  step "secret" {
    for_each = toset(local.secrets)
    command {
      command = "umask 077 && LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 64 > ${local.etc}/${item.value}.new && chgrp matrix-synapse ${local.etc}/${item.value}.new && chmod 640 ${local.etc}/${item.value}.new && mv ${local.etc}/${item.value}.new ${local.etc}/${item.value}"
      creates = "${local.etc}/${item.value}"
    }
  }

  step "config" {
    file {
      path    = "${local.etc}/homeserver.yaml"
      content = local.config
      owner   = "root"
      group   = "matrix-synapse"
      mode    = "0640"
    }
  }
}

# Synapse runs from Element's official image as a Quadlet unit on the host's
# network, so listen_address is one of the host's own. The image's start
# script drops to the UID and GID in ids.env before it starts Synapse.
module "podman" {
  source = "github.com/conn3xorg/circuit-podman?ref=v0.1.0"

  depends_on = [conn3x_file.synapse__config, conn3x_command.synapse__secret, conn3x_command.synapse__ids, conn3x_directory.synapse__data_dir]

  hosts                = var.hosts
  ssh_user             = var.ssh_user
  ssh_port             = var.ssh_port
  ssh_private_key_file = var.ssh_private_key_file
  ssh_known_hosts_file = var.ssh_known_hosts_file
  ssh_become           = var.ssh_become

  containers = {
    matrix-synapse = {
      image   = "ghcr.io/element-hq/synapse:${var.synapse_version}@${var.image_digest}"
      volumes = ["${local.etc}:/config:ro,Z", "${local.data}:/data:Z"]
      # A directory: Synapse reads every *.yaml file in it.
      environment = { SYNAPSE_CONFIG_PATH = "/config" }
      extra = [
        "Network=host",
        "EnvironmentFile=${local.ids}",
        # circuit-podman restarts the container when its unit changes, so
        # the config's hash here makes a new config take effect.
        "# homeserver.yaml sha256 ${sha256(local.config)}",
      ]
    }
  }
  secrets = var.postgres == null ? {} : {
    matrix-synapse = { PGPASSWORD = var.postgres_password }
  }
}

circuit "ready" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The first start pulls the image and creates the database. unless is
  # checked at plan time, before the restart, so anything that restarts the
  # container makes the apply check again.
  step "health" {
    depends_on = [module.podman]
    command {
      command  = "for _ in $(seq 300); do curl -sf -o /dev/null ${local.local_url}/health && exit 0; sleep 1; done; echo 'Synapse did not come up in 5 minutes. See journalctl -u matrix-synapse.' >&2; exit 1"
      unless   = "curl -sf -o /dev/null ${local.local_url}/health"
      triggers = sha256("${var.synapse_version} ${local.config}")
    }
  }

  # Write-only: the plan and state record only an HMAC of the content.
  step "admin_password" {
    for_each = toset(var.admin_user == null ? [] : [var.admin_user])
    file {
      path       = "${local.etc}/admin_password"
      content_wo = var.admin_password
      owner      = "root"
      group      = "root"
      mode       = "0600"
    }
  }

  # Runs once per admin_user. --exists-ok leaves a user that's already
  # there as it is, password included.
  step "admin" {
    for_each = toset(var.admin_user == null ? [] : [var.admin_user])
    command {
      command  = "podman exec -i matrix-synapse register_new_matrix_user -c /config/homeserver.yaml --password-file /dev/stdin -u '${item.value}' --admin --exists-ok ${local.local_url} < ${local.etc}/admin_password"
      triggers = item.value
    }
  }
}
