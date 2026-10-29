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

variable "traefik_version" {
  type        = string
  default     = "3.7.16"
  description = "Traefik release to install, without the leading v."

  validation {
    condition     = can(regex("^3\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.traefik_version))
    error_message = "traefik_version is a Traefik 3 release number without the leading v, such as \"3.7.16\"."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the release tarball for each architecture, from the release's checksums file. Change these with traefik_version."
  default = {
    amd64 = "759a7bc0d66b74c588255ed9e41c7f9d4aba60bdb7bce9dde551b1268a55eb07"
    arm64 = "8f9463a7dd3a618569aaa46e19500331d7374a2e6f6ee300a50df5bb49132e1a"
  }
}

variable "sites" {
  type = map(object({
    host     = string
    backends = list(string)
  }))
  default     = {}
  description = "Sites to route, by name. Each answers HTTPS requests for host and load-balances them across backends, a list of URLs such as \"http://127.0.0.1:3000\"."

  validation {
    condition     = alltrue([for name in keys(var.sites) : can(regex("^[A-Za-z0-9_-]+$", name))])
    error_message = "Each site name is letters, digits, - or _, such as \"photos\"."
  }

  validation {
    condition     = alltrue([for s in values(var.sites) : can(regex("^[A-Za-z0-9*][A-Za-z0-9.*-]*$", s.host))])
    error_message = "Each site's host is a host name, such as \"photos.example.com\", without a scheme, port or path."
  }

  validation {
    condition     = alltrue(flatten([for s in values(var.sites) : [length(s.backends) > 0, [for u in s.backends : can(regex("^https?://[^\\s]+$", u))]]]))
    error_message = "Each site needs at least one backend, and each backend is a URL such as \"http://127.0.0.1:3000\"."
  }
}

variable "acme_email" {
  type        = string
  default     = null
  description = "Email address for the Let's Encrypt account. When set, Traefik gets a certificate for each site's host with the HTTP challenge. When null, sites use Traefik's self-signed default certificate."

  validation {
    condition     = var.acme_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", coalesce(var.acme_email, "x@y.z")))
    error_message = "acme_email must be an address such as \"admin@example.com\"."
  }
}

variable "acme_staging" {
  type        = bool
  default     = false
  description = "Get certificates from Let's Encrypt's staging server, which browsers don't trust but which has far higher rate limits. For trying things out."
}

variable "dashboard" {
  type        = bool
  default     = false
  description = "Serve Traefik's dashboard and API on 127.0.0.1:8080, without authentication. Loopback only: reach it through an SSH tunnel."
}

variable "access_log" {
  type        = bool
  default     = false
  description = "Log every request to the journal."
}

variable "docker_provider" {
  type        = bool
  default     = false
  description = "Also route to Docker containers that opt in with the label traefik.enable=true. Needs Docker on the host, for example from circuit-docker, since the traefik user joins the docker group."
}
