variable "port" {
  type    = number
  default = 2222
}

variable "admin_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
}

module "matrix" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # A name that's only ever local. On a real server, pick it with care:
  # it can't change later.
  server_name    = "matrix.test"
  public_baseurl = "https://matrix.test/"

  admin_user     = "admin"
  admin_password = var.admin_password
}
