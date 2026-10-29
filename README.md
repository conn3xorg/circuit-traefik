# circuit-traefik

A Conn3x circuit that installs Traefik 3 from its release tarball, runs it as its own `traefik` user, and routes HTTPS to your backends from a map of sites. Give it an email address and each site gets a certificate from Let's Encrypt, which Traefik renews itself. Port 80 redirects to 443.

Sites live in a file Traefik watches, so adding or changing one takes effect without a restart. Changes to the rest of the config, such as turning on the dashboard, restart Traefik once.

## Usage

```hcl
module "traefik" {
  source = "github.com/conn3xorg/circuit-traefik?ref=v0.1.0"

  hosts                = { edge = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  acme_email = "admin@example.com"
  sites = {
    photos = { host = "photos.example.com", backends = ["http://127.0.0.1:2283"] }
    git    = { host = "git.example.com", backends = ["http://10.0.0.5:3000", "http://10.0.0.6:3000"] }
  }
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

For Let's Encrypt to issue a certificate, each site's host has to resolve to the server and port 80 has to be open to the internet, since Traefik answers the HTTP challenge there. Opening 80 and 443 is up to you; the [firewall circuit](https://github.com/conn3xorg/circuit-firewall) can do it:

```hcl
module "firewall" {
  source = "github.com/conn3xorg/circuit-firewall?ref=v0.1.0"

  hosts = { edge = "203.0.113.10" }
  allow = [{ port = "80/tcp" }, { port = "443/tcp" }]
}
```

While you're trying things out, set `acme_staging = true`. Let's Encrypt's [staging server](https://letsencrypt.org/docs/staging-environment/) works the same way, but browsers don't trust what it issues, and its rate limits are far higher. When you're happy, delete `/var/lib/traefik/acme.json`, which holds the staging account and certificates, and apply again with `acme_staging = false`. That changes the static config, so Traefik restarts and asks the production server. Without a domain to hand, name the site after the server's address under [sslip.io](https://sslip.io): `203.0.113.10.sslip.io` resolves to `203.0.113.10`, and Let's Encrypt can check it like any other name.

Without `acme_email`, every site uses Traefik's self-signed default certificate, which is fine behind another proxy or for testing, where `curl -k` will do.

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Installs curl, tar and gzip if they're missing.
2. Creates the `traefik` system user, with `/var/lib/traefik` as its home, mode `0700`. Traefik keeps its Let's Encrypt account and certificates there, in `acme.json`, which it creates with mode `0600`.
3. Downloads the Traefik 3.7.16 release tarball for the host's architecture from GitHub, checks it against a pinned SHA-256, unpacks it to `/opt/traefik/3.7.16` and links `/usr/local/bin/traefik` to it.
4. Writes the static config to `/etc/traefik/traefik.yml`: entry point `web` on port 80, which redirects to `websecure` on 443; the file provider watching `/etc/traefik/dynamic`; and, depending on the inputs, the Let's Encrypt resolver, the dashboard, the access log and the Docker provider. Traefik's update check and anonymous usage reports are off.
5. Writes `sites` to `/etc/traefik/dynamic/conn3x.yml`, one router and one load-balanced service per site.
6. Writes `/etc/systemd/system/traefik.service`. Traefik runs as `traefik` with only `CAP_NET_BIND_SERVICE`, which lets it bind ports 80 and 443, and with the filesystem read-only apart from `/var/lib/traefik`.
7. Restarts Traefik when the static config, the unit or the version changes, since Traefik reads its static config only at start. A change to `sites` alone doesn't restart it.
8. Starts Traefik now and at boot, and waits up to a minute for it to listen on 443. If Traefik doesn't come up, the apply fails here, and `journalctl -u traefik` says why.

Each site becomes a router with the rule ``Host(`HOST`)`` on `websecure` and a service that spreads requests across its backends in turn. With `acme_email` set, the `websecure` entry point asks the `letsencrypt` resolver for a certificate for every router on it, so you don't name the resolver per site.

The `static_config` and `dynamic_config` outputs show exactly what the circuit writes.

Before the circuit runs, the `conn3x_host` data source reads each host's architecture over SSH. The tarball is pinned for x86_64 and aarch64; another architecture fails the plan.

### Your own dynamic config

Traefik reads every file in `/etc/traefik/dynamic`, and the circuit only manages `conn3x.yml`. For middlewares, TCP routers or anything else `sites` doesn't cover, put another YAML file beside it with your own `file` step. Traefik picks it up without a restart, the same way it picks up changes to `sites`.

### The dashboard

`dashboard = true` serves Traefik's dashboard and API on `127.0.0.1:8080`, without authentication, so only the host itself can reach it. Open a tunnel and browse to `http://localhost:8080/dashboard/`:

```sh
ssh -L 8080:127.0.0.1:8080 root@203.0.113.10
```

### Docker containers

On a host that runs Docker, for example from [circuit-docker](https://github.com/conn3xorg/circuit-docker), `docker_provider = true` lets Traefik route to containers too. It adds the `traefik` user to the `docker` group so it can read the Docker socket, and it only routes to containers that ask for it with labels:

```sh
docker run -d --name whoami \
  --label traefik.enable=true \
  --label 'traefik.http.routers.whoami.rule=Host(`whoami.example.com`)' \
  traefik/whoami
```

The `docker` group has to exist before this circuit runs, so put `depends_on = [module.docker]` on this module. Membership of `docker` is as good as root on that host, so it's off by default.

## What it doesn't cover

- Firewall ports. Open 80 and 443 yourself or with the [firewall circuit](https://github.com/conn3xorg/circuit-firewall).
- Other ACME challenges. Certificates come through the HTTP challenge on port 80, so wildcard names and hosts that aren't reachable from the internet need a DNS challenge, which you'd configure yourself.
- Ports other than 80 and 443, and plain-HTTP sites: port 80 always redirects.
- Authentication on the dashboard. It listens on loopback only for that reason.
- Removing Traefik. Deleting the module leaves Traefik installed and running.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `traefik_version` | string | `"3.7.16"` | Traefik 3 release to install, without the leading v. |
| `checksums` | map(string) | the 3.7.16 tarballs | SHA-256 of the release tarball for `amd64` and `arm64`, from the release's `traefik_vVERSION_checksums.txt`. Change these with `traefik_version`. |
| `sites` | map(object) | `{}` | Sites to route, by name: letters, digits, `-` and `_`. Each takes `host`, the name it answers to, such as `"photos.example.com"`, and `backends`, a list of URLs such as `["http://127.0.0.1:2283"]`. |
| `acme_email` | string | `null` | Email address for the Let's Encrypt account. When set, Traefik gets a certificate for each site. When null, sites use Traefik's self-signed default certificate. |
| `acme_staging` | bool | `false` | Get certificates from Let's Encrypt's staging server, which browsers don't trust but which has far higher rate limits. |
| `dashboard` | bool | `false` | Serve the dashboard and API on `127.0.0.1:8080`, without authentication. |
| `access_log` | bool | `false` | Log every request to the journal. |
| `docker_provider` | bool | `false` | Also route to Docker containers labelled `traefik.enable=true`. Adds the `traefik` user to the `docker` group. |

## Outputs

| Name | Description |
| --- | --- |
| `static_config` | The static configuration the circuit writes to `/etc/traefik/traefik.yml`. |
| `dynamic_config` | The routers and services the circuit writes to `/etc/traefik/dynamic/conn3x.yml`. |
| `version` | The Traefik version the circuit installs, such as `"3.7.16"`. |

## Requirements

Requires Conn3x v0.6.7 or later and systemd on each host, with outbound HTTPS to github.com, and to Let's Encrypt when `acme_email` is set.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes. It then fetches a site through Traefik over HTTPS and sees it balanced across two backends, checks that plain HTTP redirects to HTTPS, and adds a second site and fetches it from the same Traefik process, unrestarted. The CI containers run with SELinux off. Certificates were tried by hand on an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, each with a site named after its address through sslip.io and `acme_staging = true`: Traefik got a staging certificate from Let's Encrypt, the site came back over HTTPS, HTTP redirected, `acme.json` was mode `0600`, and the second plan had no changes. On Rocky, Traefik ran as `unconfined_service_t` and the audit log had no denials. After a reboot both sites came back and the plan still had no changes. On the Ubuntu droplet, with Docker from circuit-docker and `docker_provider = true`, a labelled container got its own staging certificate and was served through Traefik.

## License

MPL-2.0. See [LICENSE](LICENSE). Traefik itself is MIT.
