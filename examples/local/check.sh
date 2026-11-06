# Run on the host: the site balances across both backends, over Traefik's
# self-signed default certificate, and plain HTTP redirects to HTTPS.
set -eu
for _ in $(seq 30); do
  curl -sfk --resolve app.test:443:127.0.0.1 https://app.test/ >/dev/null && break
  sleep 1
done
out=""
for _ in 1 2 3 4 5 6; do
  out="$out $(curl -sSfk --resolve app.test:443:127.0.0.1 https://app.test/)"
done
echo "$out"
echo "$out" | grep -q 'backend a'
echo "$out" | grep -q 'backend b'
r=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: app.test' http://127.0.0.1/)
echo "$r"
echo "$r" | grep -Eq '^30[178] https://app.test/'
