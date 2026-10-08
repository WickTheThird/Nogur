# Nogur TURN deployment

Run coturn on a public Linux VM with a public IPv4 address.

## DNS and certificates

1. Point `turn.bumbuindustries.com` directly at the VM. Keep the DNS record
   unproxied.
2. Issue a TLS certificate for that hostname and set `TURN_CERT_DIRECTORY` to
   the directory containing `fullchain.pem` and `privkey.pem`.
3. Generate one shared secret with `openssl rand -hex 32`. Set the identical
   value as `NOGUR_TURN_SHARED_SECRET` for the API and coturn.

## Firewall

Allow inbound TCP and UDP 3478 and 5349, plus UDP 49160 through 49259. Keep
9641 private. The compose file binds Prometheus metrics to localhost only.

## Start

Set these values in the deployment environment:

```text
TURN_EXTERNAL_IP=<public VM IPv4>
TURN_CERT_DIRECTORY=/etc/letsencrypt/live/turn.bumbuindustries.com
NOGUR_TURN_SHARED_SECRET=<shared secret>
NOGUR_TURN_URLS=turn:turn.bumbuindustries.com:3478?transport=udp,turn:turn.bumbuindustries.com:3478?transport=tcp,turns:turn.bumbuindustries.com:5349?transport=tcp
```

Then run:

```sh
docker compose -f compose.turn.yaml up -d
```

Use the same `NOGUR_TURN_URLS` and secret in the API container. Credentials
returned by `/v1/sessions/{id}/transport` expire after ten minutes by default.

## Prove the deployment

Install coturn's command-line utilities on a machine outside the VM network,
then run `ops/coturn/test-turn.sh`. Run it once from each of two unrelated home
or mobile networks. For the app test, temporarily remove STUN URLs from the API
configuration so WebRTC must use a relay candidate.

Inspect `http://127.0.0.1:9641/metrics` on the VM through SSH for allocations,
traffic, failures, and relayed bandwidth. Alert on sustained allocation
failures, unexpected allocation growth, or bandwidth nearing the VM limit.
