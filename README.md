# ci-netlab

Remote-controlled network lab running on GitHub Actions (the same environment as the CI jobs).

Purpose: test `Xiaobei09/proxyip` **relay IPs used via force-resolve** (`--connect-to` / hosts + SNI),
not HTTP CONNECT proxies, and measure whether an OpenCode free-tier quota is available on the
relay's egress IP.

## Usage

All runs are triggered manually (`workflow_dispatch`), so this repo never runs on push.

```bash
# 1) probe relays: connectivity + real egress IP (entry -> exit mapping)
gh workflow run lab.yml -R Xiaobei09/ci-netlab -f mode=probe -f count=12 -f source=all.txt

# 2) quota test through one relay (blank relay = auto-pick)
gh workflow run lab.yml -R Xiaobei09/ci-netlab -f mode=quota -f relay=1.2.3.4:443

# 3) arbitrary shell in the CI environment
gh workflow run lab.yml -R Xiaobei09/ci-netlab -f mode=shell -f command='uname -a; curl -sS https://icanhazip.com'

# watch / read logs
gh run list -R Xiaobei09/ci-netlab -L 3
gh run watch -R Xiaobei09/ci-netlab <run-id>
gh run view -R Xiaobei09/ci-netlab <run-id> --log
```

## How quota mode works

1. Install OpenCode 2 (`https://opencode.ai/v2/install`), same as production CI.
2. Force-resolve `opencode.ai` to the relay:
   - port 443: append `<ip> opencode.ai` to `/etc/hosts`;
   - other CF edge ports (2053/2083/2087/2096/8443): local TCP forwarder `127.0.0.1:443 -> ip:port`
     plus `127.0.0.1 opencode.ai` in `/etc/hosts`.
3. Run the real client: `opencode run --standalone --model opencode/big-pickle "hi"`.
4. Classify the result: `SUCCESS` / `LIMITED` (FreeUsageLimitError) / `ERROR`.

Note: `proxyip` entries are **relay/SNI IPs** (non-CF ASN + Cloudflare edge ports), so `curl -x`
(CONNECT) is the wrong test and reports 0 usable — use `--connect-to` or hosts-based force-resolve.
