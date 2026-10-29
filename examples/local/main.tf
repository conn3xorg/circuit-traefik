variable "port" {
  type    = number
  default = 2222
}

# Set true to add a second site. Traefik picks it up without a restart.
variable "second_site" {
  type    = bool
  default = false
}

locals {
  hosts = { box = "127.0.0.1" }
}

# Two tiny backends to proxy to: Python's http.server on 9001 and 9002,
# each serving a page that names it.
circuit "backends" {
  hosts = local.hosts

  ssh {
    user             = "root"
    port             = var.port
    private_key_file = "./id_ed25519"
    known_hosts_file = "./known_hosts"
  }

  step "python" {
    package {
      name = "python3"
    }
    # After the module, so its apt or dnf run doesn't overlap this one.
    depends_on = [module.traefik]
  }

  step "page" {
    for_each = toset(["a", "b"])
    file {
      path    = "/srv/backend-${item.value}/index.html"
      content = "backend ${item.value}\n"
    }
  }

  step "unit" {
    for_each = { a = 9001, b = 9002 }
    file {
      path    = "/etc/systemd/system/backend-${item.key}.service"
      content = <<-EOT
        [Service]
        ExecStart=/usr/bin/python3 -m http.server ${item.value} --bind 127.0.0.1 --directory /srv/backend-${item.key}
        User=nobody

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  step "running" {
    for_each = toset(["a", "b"])
    service {
      name    = "backend-${item.value}"
      state   = "started"
      enabled = true
    }
  }
}

module "traefik" {
  source = "../.."

  hosts                = local.hosts
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # A container has no public DNS name to get a certificate for, so the
  # sites use Traefik's self-signed default. curl needs -k.
  sites = merge(
    { app = { host = "app.test", backends = ["http://127.0.0.1:9001", "http://127.0.0.1:9002"] } },
    var.second_site ? { only_b = { host = "b.test", backends = ["http://127.0.0.1:9002"] } } : {},
  )
  access_log = true
}

output "dynamic_config" {
  value = module.traefik.dynamic_config
}
