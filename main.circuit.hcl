# Facts give each host's architecture, which picks the release tarball.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  goarch  = { x86_64 = "amd64", aarch64 = "arm64" }
  arch    = { for name, f in data.conn3x_host.facts : name => local.goarch[f.arch] }
  tarball = { for name, a in local.arch : name => "/opt/traefik/traefik_v${var.traefik_version}_linux_${a}.tar.gz" }
  bin_dir = "/opt/traefik/${var.traefik_version}"

  static_file  = "/etc/traefik/traefik.yml"
  dynamic_dir  = "/etc/traefik/dynamic"
  dynamic_file = "/etc/traefik/dynamic/conn3x.yml"
  data_dir     = "/var/lib/traefik"

  acme = var.acme_email != null

  # Port 80 only redirects to 443, apart from Let's Encrypt's HTTP challenge,
  # which Traefik answers before the redirect. Every router on websecure gets
  # TLS: a certificate from the resolver when there is one, otherwise
  # Traefik's own self-signed default.
  static = merge(
    {
      global = { checkNewVersion = false, sendAnonymousUsage = false }
      entryPoints = merge(
        {
          web = {
            address = ":80"
            http    = { redirections = { entryPoint = { to = "websecure", scheme = "https" } } }
          }
          websecure = {
            address = ":443"
            http    = { tls = local.acme ? { certResolver = "letsencrypt" } : {} }
          }
        },
        var.dashboard ? { traefik = { address = "127.0.0.1:8080" } } : {},
      )
      providers = merge(
        { file = { directory = local.dynamic_dir, watch = true } },
        var.docker_provider ? { docker = { exposedByDefault = false } } : {},
      )
    },
    # api.insecure serves the dashboard on the traefik entry point, which
    # listens on loopback only. Reach it through an SSH tunnel.
    var.dashboard ? { api = { dashboard = true, insecure = true } } : {},
    var.access_log ? { accessLog = {} } : {},
    local.acme ? {
      certificatesResolvers = {
        letsencrypt = {
          acme = {
            email         = var.acme_email
            storage       = "${local.data_dir}/acme.json"
            caServer      = var.acme_staging ? "https://acme-staging-v02.api.letsencrypt.org/directory" : "https://acme-v02.api.letsencrypt.org/directory"
            httpChallenge = { entryPoint = "web" }
          }
        }
      }
    } : {},
  )
  static_yaml = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${yamlencode(local.static)}"

  dynamic = length(var.sites) == 0 ? {} : {
    http = {
      routers = { for name, s in var.sites : name => {
        rule        = "Host(`${s.host}`)"
        entryPoints = ["websecure"]
        service     = name
      } }
      services = { for name, s in var.sites : name => {
        loadBalancer = { servers = [for u in s.backends : { url = u }] }
      } }
    }
  }
  dynamic_yaml = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${length(var.sites) == 0 ? "" : yamlencode(local.dynamic)}"
}

circuit "traefik" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Minimal images can lack any of these.
  step "tools" {
    for_each = toset(["curl", "tar", "gzip"])
    package {
      name = item.value
    }
  }

  # With the Docker provider on, the traefik user joins the docker group to
  # read the Docker socket. Otherwise its groups are left alone.
  step "user" {
    user {
      name   = "traefik"
      system = true
      home   = local.data_dir
      shell  = "/usr/sbin/nologin"
      groups = var.docker_provider ? ["docker"] : null
    }
  }

  # Holds acme.json, which Traefik creates with mode 0600 and refuses to use
  # with any looser one.
  step "data" {
    directory {
      path  = local.data_dir
      owner = "traefik"
      group = "traefik"
      mode  = "0700"
    }
  }

  step "download" {
    download {
      url    = "https://github.com/traefik/traefik/releases/download/v${var.traefik_version}/traefik_v${var.traefik_version}_linux_${local.arch[each.key]}.tar.gz"
      sha256 = var.checksums[local.arch[each.key]]
      dest   = local.tarball[each.key]
    }
  }

  step "unpack" {
    archive {
      src     = local.tarball[each.key]
      dest    = local.bin_dir
      creates = "${local.bin_dir}/traefik"
    }
  }

  step "binary" {
    link {
      path   = "/usr/local/bin/traefik"
      target = "${local.bin_dir}/traefik"
    }
  }

  step "dynamic_dir" {
    directory {
      path = local.dynamic_dir
    }
  }

  step "static" {
    file {
      path    = local.static_file
      content = local.static_yaml
    }
  }

  # Traefik watches this directory and picks up changes to the file on its
  # own, so a new or changed site needs no restart.
  step "dynamic" {
    file {
      path    = local.dynamic_file
      content = local.dynamic_yaml
    }
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/traefik.service"
      content = <<-EOT
        [Unit]
        Description=Traefik
        Documentation=https://doc.traefik.io/traefik/
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=traefik
        Group=traefik
        ExecStart=/usr/local/bin/traefik --configFile=${local.static_file}
        Restart=on-failure
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        CapabilityBoundingSet=CAP_NET_BIND_SERVICE
        NoNewPrivileges=true
        ProtectSystem=strict
        ProtectHome=true
        PrivateTmp=true
        ReadWritePaths=${local.data_dir}
        LimitNOFILE=1048576

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # Restarts Traefik when the static config, the unit or the version
  # changes: Traefik reads its static config only at start. This is a step
  # rather than a handler because handlers run after every step, and the
  # ready check below has to see Traefik running with the new config.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart traefik"
      triggers = {
        version = var.traefik_version
        static  = conn3x_file.traefik__static[each.key].revision
        unit    = conn3x_file.traefik__unit[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "traefik"
      state   = "started"
      enabled = true
    }
  }

  # A static config Traefik can't start with shows up here, rather than as
  # an apply that succeeds while nothing listens.
  step "ready" {
    wait_for {
      port    = 443
      timeout = "1m"
    }
  }
}
