# circuit-matrix

[![Conn3x grade](https://conn3x.org/circuits/matrix/grade.svg)](https://conn3x.org/circuits/matrix/grade)

A Conn3x circuit that runs [Synapse](https://github.com/element-hq/synapse), the reference Matrix homeserver, so you and your people can chat from Element or any other Matrix client on a server you own, and still talk to everyone else on Matrix through federation.

Synapse runs from Element's official image under Podman as a systemd service, listening on `127.0.0.1:8008` for a reverse proxy in front. You give it a server name, the URL clients reach it at and, if you want one, an admin user. The secrets Synapse signs things with are made on the host and never leave it. SQLite is fine for a trial; for anything you'll keep, point it at PostgreSQL, such as one from [circuit-postgres](https://github.com/conn3xorg/circuit-postgres).

It's deliberately the core and nothing else. [matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy) sets up dozens of bridges, bots and clients around Synapse; this circuit gives you a homeserver that works and stays the way you described it, and leaves the rest to you.

## Pick server_name once

**`server_name` can never change.** It's the part after the colon in every user ID and room alias, `@alice:example.com`, and other servers remember it. Change it after the first start and Synapse refuses to run with the old database; the only way back is a fresh database, which means everyone's accounts and rooms are gone.

Most people want their plain domain, `example.com`, so IDs look like email addresses, with Synapse itself on `matrix.example.com`. That takes delegation through `.well-known`, covered under [Behind a reverse proxy](#behind-a-reverse-proxy). If you're only trying it out, use a name you'll throw away, such as `matrix-test.example.com`.

## Usage

```hcl
variable "admin_password" {
  type      = string
  ephemeral = true
}

module "matrix" {
  source = "github.com/conn3xorg/circuit-matrix?ref=v0.1.1"

  hosts                = { chat = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  server_name    = "example.com"
  public_baseurl = "https://matrix.example.com/"

  admin_user     = "admin"
  admin_password = var.admin_password
}
```

Then run `conn3x init` and `conn3x apply -var admin_password=...`. A second `conn3x plan` says `No changes.` Sign in from [Element](https://app.element.io) as `@admin:example.com` once the reverse proxy is in place.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry:

```hcl
hosts = {
  for name, d in digitalocean_droplet.chat : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Behind a reverse proxy

Synapse speaks plain HTTP on `127.0.0.1:8008` and trusts the proxy's `X-Forwarded-For`. The proxy needs to send two things to it:

- Everything on the host in `public_baseurl`, such as `matrix.example.com`. Clients and other servers both use it.
- `/.well-known/matrix/` on `server_name`'s own domain, when that's a different host, such as `example.com`. Synapse answers `/.well-known/matrix/server` with `matrix.example.com:443`, which tells other servers where to find it, and `/.well-known/matrix/client` with `public_baseurl`, which tells clients.

With [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) on the same host, that's:

```hcl
module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.2.1"

  hosts                = { chat = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  email = "admin@example.com"
  sites = {
    "matrix.example.com" = { reverse_proxy = ["localhost:8008"] }
    "example.com"        = { extra = "reverse_proxy /.well-known/matrix/* localhost:8008" }
  }
}
```

If `example.com` is a website served somewhere else, put those two files there instead; each is a few bytes of JSON, and the [Synapse delegation docs](https://element-hq.github.io/synapse/latest/delegate.html) show them. With Traefik, nginx or anything else, the rules are the same: proxy the whole `matrix.example.com` host, and `/.well-known/matrix/` on `example.com`. Allow request bodies up to Synapse's upload limit, 50 MB by default; Caddy and Traefik don't cap them, nginx does at 1 MB.

The Caddy snippet above is how the pieces fit, not something CI runs. Federation hasn't been tried end to end.

### PostgreSQL

SQLite in `/var/lib/matrix-synapse` is the default, and Synapse's own docs say it's only for testing. For PostgreSQL, pass `postgres` and `postgres_password`:

```hcl
postgres          = { host = "127.0.0.1", database = "synapse", username = "synapse" }
postgres_password = var.synapse_db_password
```

The password goes to the container's env file, mode `0600`, as `PGPASSWORD`, and never reaches the plan, state or `homeserver.yaml`. The role and database have to exist first, and **the database must use the C collation**, or Synapse refuses to start. circuit-postgres creates the role; create the database with the right locale yourself, for example from your own root module:

```hcl
module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = { chat = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  users          = ["synapse"]
  user_passwords = { synapse = var.synapse_db_password }
}

# In a .circuit.hcl file next to it.
circuit "synapse_db" {
  hosts = { chat = "203.0.113.10" }

  ssh {
    user             = "root"
    private_key_file = "~/.ssh/id_ed25519"
  }

  step "create" {
    depends_on = [module.postgres]
    command {
      command = "runuser -u postgres -- createdb --owner=synapse --encoding=UTF8 --locale=C --template=template0 synapse"
      unless  = "runuser -u postgres -- psql -tAc \"SELECT 1 FROM pg_database WHERE datname = 'synapse'\" | grep -q 1"
    }
  }
}
```

Then give the Synapse module `depends_on = [conn3x_command.synapse_db__create]`. circuit-postgres's default `pg_hba.conf` already lets the `synapse` role in over `127.0.0.1` with a password. Moving an existing SQLite database over is a job for Synapse's [`synapse_port_db`](https://element-hq.github.io/synapse/latest/postgres.html#porting-from-sqlite), not this circuit.

### Other settings

Anything else in `homeserver.yaml` goes in `settings`, merged over the circuit's own at the top level. To let people sign up with a token you hand out:

```hcl
settings = {
  enable_registration         = true
  registration_requires_token = true
  max_upload_size             = "100M"
}
```

Make tokens with the [admin API](https://element-hq.github.io/synapse/latest/usage/administration/admin_api/registration_tokens.html). Open registration with no token, email or captcha is how a homeserver ends up full of spam accounts, and Synapse won't start that way unless you also set `enable_registration_without_verification`.

## Why a container

Element publishes Synapse two ways: Debian and Ubuntu packages from `packages.matrix.org`, and the `element-hq/synapse` image. There's nothing official for Rocky Linux or RHEL, and Fedora's `matrix-synapse` is a downstream package that Fedora maintains. The packages are also amd64 only. The image covers all four distributions, amd64 and arm64, with the same Synapse build, so this circuit uses it everywhere:

- **One pin.** `synapse_version` is an image tag, and `image_digest` pins it. Change both and `conn3x plan` shows the new tag in the unit file; the apply restarts Synapse on it, and Synapse migrates its database on start.
- **The same layout on every host.** The config lives in `/etc/matrix-synapse` and the data in `/var/lib/matrix-synapse` whichever distribution is underneath.

The container uses the host's network, so `listen_address` is one of the host's own and a proxy on the host reaches it at `localhost:8008`.

## What it does

On each host, in order:

1. Installs `curl`, then creates a `matrix-synapse` system group and user. Their IDs are whatever the host hands out, and go into `/etc/matrix-synapse/ids.env` for the container, which runs Synapse as that user. The image's default, 991, is already taken on Ubuntu's cloud image.
2. Creates `/etc/matrix-synapse`, root's and readable by the group, and `/var/lib/matrix-synapse`, which only `matrix-synapse` can open.
3. Generates `registration_shared_secret`, `macaroon_secret_key` and `form_secret` in `/etc/matrix-synapse`, 64 random letters and digits each, mode `0640`. They're made on the first apply and never again, since a new macaroon key would sign everyone out. Synapse reads them through its `*_path` settings, so they're in neither `homeserver.yaml` nor the state.
4. Writes `/etc/matrix-synapse/homeserver.yaml`: your server name and URL, one HTTP listener for the client and federation APIs, the database, registration off, stats reporting off, and the federation `.well-known` on. Then whatever's in `settings`.
5. Through [circuit-podman](https://github.com/conn3xorg/circuit-podman) v0.1.0, installs Podman and runs `ghcr.io/element-hq/synapse:VERSION` as `matrix-synapse.service`, with `/etc/matrix-synapse` mounted read-only at `/config` and `/var/lib/matrix-synapse` at `/data`. A changed `homeserver.yaml` restarts it.
6. Waits for `/health` to answer, up to five minutes.
7. With `admin_user`, writes the password to `/etc/matrix-synapse/admin_password`, mode `0600`, and creates the user with Synapse's `register_new_matrix_user` and the shared secret.

On its first start, Synapse makes its signing key, `/var/lib/matrix-synapse/signing.key`. Other servers know your server by that key: back it up with the rest of `/var/lib/matrix-synapse`, which also holds the media store and, with SQLite, the database.

### The admin password

`register_new_matrix_user` only creates users, so `admin_password` is the password the admin starts with. The circuit creates the user once per `admin_user`, and leaves a user that already exists alone. Change the password afterwards in Element; a new `admin_password` updates the file on the host but not the account.

### What it doesn't do

- It doesn't set up the reverse proxy, TLS or DNS. See [Behind a reverse proxy](#behind-a-reverse-proxy).
- It doesn't open ports. With the defaults Synapse is on loopback only; open 443 for the proxy.
- It doesn't install Element Web, bridges, TURN for calls, or workers. Those are the parts matrix-docker-ansible-deploy is for.
- It doesn't create the PostgreSQL database, or move a SQLite one to PostgreSQL.
- Deleting the module leaves Podman, the container, the config and the data in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `server_name` | string | Required | The domain in every user ID, such as `"example.com"` for `@alice:example.com`. **It can never change** once Synapse has started. |
| `public_baseurl` | string | Required | URL clients reach Synapse at through your proxy, such as `"https://matrix.example.com/"`. |
| `synapse_version` | string | `"v1.164.1"` | Tag of `ghcr.io/element-hq/synapse`. |
| `image_digest` | string | The digest of `v1.164.1` | Digest of the image. Podman pulls by the digest, so set it whenever you change `synapse_version`. |
| `listen_address` | string | `"127.0.0.1"` | Address Synapse listens on. |
| `listen_port` | number | `8008` | Port of the client and federation APIs, in plain HTTP. |
| `postgres` | object | `null` | PostgreSQL to use, with optional `host` (`"127.0.0.1"`), `port` (`5432`), `database` (`"synapse"`) and `username` (`"synapse"`). The database must exist with C collation. When null, SQLite. |
| `postgres_password` | string | `null` | Password of the PostgreSQL user. Needed with `postgres`. Ephemeral and sensitive: it reaches the container's env file but never the plan or state. |
| `admin_user` | string | `null` | Localpart of an admin user to create, such as `"admin"`. When null, none. |
| `admin_password` | string | `null` | Password the admin user is created with, 8 characters or more. Needed with `admin_user`. Ephemeral and sensitive. |
| `settings` | any | `{}` | Extra `homeserver.yaml` settings, merged at the top level. Can't set the server name, URL, listeners, database, key and media paths or secrets. |

## Outputs

| Name | Description |
| --- | --- |
| `service` | The systemd service that runs Synapse, `matrix-synapse.service`. |
| `image` | The image the hosts run, such as `ghcr.io/element-hq/synapse:v1.164.1`. |
| `local_url` | Where Synapse listens on each host, such as `http://127.0.0.1:8008`, for the proxy. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, which needs to reach its package mirror and `ghcr.io`. `conn3x init` fetches circuit-podman from GitHub.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes. It checks `/_matrix/client/versions` answers, the example's admin logs in through `/_matrix/client/v3/login` and is an admin, a wrong password is turned down, and `/.well-known/matrix/server` names the server. It checks the generated secrets are root's and not in `homeserver.yaml`. Then it restarts Synapse, logs in again and plans again.

The same checks passed by hand on arm64 containers of all four, and on two 2 GB droplets. On Ubuntu 24.04, Synapse ran against PostgreSQL 18 from circuit-postgres v0.2.0, with the database created as shown above, and ran as the `matrix-synapse` user with ID 999, since 991 is `systemd-resolve` there. On Rocky Linux 10, with SELinux enforcing, it ran on SQLite with no denials in the audit log. Adding a setting restarted Synapse with a clean plan after, and both came back after a reboot with the admin still able to log in and no changes in the plan.

Upgrading from one `synapse_version` to the next hasn't been tried yet.

## License

MPL-2.0. See [LICENSE](LICENSE). Synapse itself is AGPL-3.0.
