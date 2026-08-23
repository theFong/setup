# Exposing an agent UI safely on Brev

The working shape, and why each piece is load-bearing. Skip a layer and you have
published a shell.

```
browser ──► brev secure link (Pomerium → SSO, authorizedEmails)
              │
              ▼
        nginx :9119 ── rewrites Host AND Origin ──► hermes 127.0.0.1:9120
              ▲
              └── iptables: only brev ingress peers may reach :9119
                  (because a SHARED mesh node is reachable by every peer)
```

## Why the proxy exists at all

Hermes' DNS-rebinding guard has **no allowed-hosts setting**:

| bind | its auth gate | Host/Origin accepted |
|---|---|---|
| `0.0.0.0` | **forced ON** (`--insecure` is a documented no-op) | any |
| `127.0.0.1` | off | **loopback only** |

Loopback-bound is what we want (SSO should be the single gate), but then brev's
`Host: myagent-xxxx.apps.run.<your-brev-domain>` is rejected. nginx normalises both headers.

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 9119;
    proxy_buffering off;            # /api/pty is a live terminal
    proxy_request_buffering off;

    location / {
        proxy_pass http://127.0.0.1:9120;

        proxy_set_header Host   127.0.0.1:9120;
        proxy_set_header Origin http://127.0.0.1:9120;   # omit -> ws 1006 loop

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 3600s;   # server pings every 20s; idle chat must survive
        proxy_send_timeout 3600s;
    }
}
```
Trade-off to state plainly: **rewriting `Origin` forfeits that layer's CSRF protection.**
Acceptable only because the port is firewalled and SSO-fronted. Never on a public bind.

## The firewall — the piece people skip

If the instance is `NETWORK_MEMBER_TYPE_SHARED`, **every mesh peer can reach its ports
directly and never sees the SSO.** Verified on a live box before the rule: another node
got HTTP 200 on `/api/status`.

```bash
#!/usr/bin/env bash
# /usr/local/sbin/agent-firewall.sh  — run from a systemd oneshot at boot.
set -euo pipefail
INGRESS_IPS="<ingress-ip-1> <ingress-ip-2> <ingress-ip-3>"   # brev ingress peers
PORTS="9119 7682 8888"     # EVERY locally-exposed port. Not 22 (key-only; lockout risk).
CHAIN=AGENT-EXPOSED

if sudo iptables -L "$CHAIN" -n >/dev/null 2>&1; then
  for p in $PORTS; do sudo iptables -D INPUT -p tcp --dport "$p" -j "$CHAIN" 2>/dev/null || true; done
  sudo iptables -F "$CHAIN"
else
  sudo iptables -N "$CHAIN"
fi

sudo iptables -A "$CHAIN" -i lo -j ACCEPT              # nginx -> app, health probes
sudo iptables -A "$CHAIN" -s 127.0.0.1 -j ACCEPT
for ip in $INGRESS_IPS; do sudo iptables -A "$CHAIN" -s "$ip" -j ACCEPT; done
# LOG before DROP so a wrong ingress guess is diagnosable, not a silent outage.
sudo iptables -A "$CHAIN" -m limit --limit 6/min -j LOG --log-prefix "AGENT-DENY " --log-level 4
sudo iptables -A "$CHAIN" -j DROP
for p in $PORTS; do sudo iptables -I INPUT -p tcp --dport "$p" -j "$CHAIN"; done
```

**iptables does not survive reboot** — wrap it:
```ini
[Unit]
Description=Restrict agent ports to brev ingress
After=network-online.target netbird.service
Before=nginx.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agent-firewall.sh
[Install]
WantedBy=multi-user.target
```

### Verify from ANOTHER host
```bash
ssh other-node 'curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://<agent-mesh-ip>:9119/'
# 000 = correctly blocked
```
Probing the agent's own mesh IP **from the agent** is routed over `lo`, which the chain
allows — it returns 200 and looks like a breach that is not one.

### Audit coverage generically
A hardcoded port list rots. Diff listeners against rules instead:
```bash
sudo ss -ltn | awk 'NR>1{print $4}' | grep -E '^(0\.0\.0\.0|\[::\])' \
| sed 's/.*://' | sort -un | while read p; do
    sudo iptables -L INPUT -n | grep -q "dpt:$p" \
      && echo "  $p firewalled" || echo "  $p ** EXPOSED TO MESH **"
  done
```
This is how a forgotten Jupyter on 8888 was caught after the fact.

## Creating the link

```bash
curl -X POST "https://api.brev.dev/devplaneapi.v1.EnvironmentService/OpenHTTPPort" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"environmentId":"<instance-id>","portNumber":9119,
       "httpProtocol":"HTTP_PORT_PROTOCOL_HTTP",
       "customHostname":"myagent-<instance-id>",
       "authorizedEmails":["you@example.com"],
       "allowPublicUnauthenticated":false}'
```
`customHostname` must already carry the `-<instanceId>` suffix; `authorizedEmails` is a
plain array here but a `{"emails":[…]}` wrapper in `SetHTTPPortAccess`. See `brev-cli`.

**Audit exposures regularly** — `allowPublicUnauthenticated: true` is the whole internet:
```bash
curl -s -X POST "https://api.brev.dev/devplaneapi.v1.EnvironmentService/GetNetworkInfo" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"environmentId":"<id>"}' \
| jq '.networkInfo.ports[] | {hostname, serverPort, authorizedEmails, allowPublicUnauthenticated}'
```

## Hardening the agent itself

- `HERMES_DASHBOARD_FILES_ROOT=/path/to/jail` — **the Files API has no path containment
  on a native install**; without it an authenticated session reads any file the user can.
- An authenticated session is equivalent to a shell: `/api/pty` (terminal), `/api/env`
  (all secrets), `/api/ops/hooks` (arbitrary shell hooks).
- Some endpoints bypass auth by design even when gated — `/api/health`, `/api/status`,
  `/api/config/defaults`. `/api/status` leaks version and session counts.
- Upstream cites a June 2026 campaign where internet-exposed dashboards were driven into
  planting SSH backdoors. Their own guidance: VPN or tunnel, never a bare public bind.

## Adding a utility shell (ttyd)

Same treatment, one extra warning: **ttyd has no approval layer** — `approvals.deny`
governs the Hermes agent, not a raw terminal. Where the service user has passwordless
sudo it is a root shell.

Bind it to **loopback** regardless of mode, front it with nginx (ttyd needs no Origin
rewrite — it does not check origin unless `--check-origin`), add its port to `PORTS`
**in the same change**, and give it its own SSO link.

Its own password is optional and worth thinking about rather than defaulting:

| | with ttyd password | without |
|---|---|---|
| normal path | SSO → firewall → password | SSO → firewall |
| **if the firewall fails** | password still stands | instant root shell |

So keep it **unless** something co-located is already unauthenticated behind the same
firewall — a Hermes dashboard exposes `/api/pty`, which is itself a shell, so a firewall
failure already yields root and the extra password buys inconsistency, not defense.
Decide once and apply it to every surface on the host.

`--public --iface lo` gives loopback with no credential; "public" here means *no
built-in auth, an auth proxy is assumed*, **not** bind `0.0.0.0`.
