# Local example

Applies circuit-traefik to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

A second circuit in `main.tf` starts two tiny backends, Python's `http.server` on ports 9001 and 9002, each serving a page that names it. The site `app.test` balances across both. The container has no public DNS name, so there's no Let's Encrypt here: Traefik serves its self-signed default certificate, and `curl` needs `-k`.

```sh
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To look at the result, fetch the site a few times through Traefik and watch the two backends take turns:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  'for i in 1 2 3 4; do curl -sk --resolve app.test:443:127.0.0.1 https://app.test/; done'
```

Plain HTTP answers with a redirect to HTTPS. To see a new site picked up without a restart, apply again with `-var second_site=true`, then fetch `https://b.test/` the same way. `systemctl show -P MainPID traefik` gives the same process ID before and after.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, the key and the state.
