# Codex model proxy

This localhost-only Responses API router lets Codex CLI and Codex Desktop use
OpenAI/ChatGPT models and models from another Responses-compatible API in one
picker.

Install and configure it from the repository root with `codex-setup.sh`. The
source files in this directory are downloaded to `~/.codex/model-proxy` by the
installer; there are no npm dependencies. During each install, the setup script
queries the custom API's authenticated `/v1/models` endpoint and stores the
returned model metadata. Routing and Codex catalog generation use that
discovered list, so keys with different access receive different pickers and
future models are picked up on the next re-run. The upstream must support the
OpenAI Responses protocol; this proxy does not translate Chat Completions.

## Security

- The server binds to `127.0.0.1` by default.
- OpenAI credentials are forwarded only to OpenAI or the ChatGPT Codex backend.
- The incoming OpenAI credential and ChatGPT account header are removed before
  a custom API request, which receives only that API's key.
- Request bodies, response bodies, credentials, and headers are not logged.
- `~/.codex/model-proxy/upstream.json` is written with mode `0600`.

Any process running as the same OS user can already read that user's Codex and
custom API credential stores; the loopback listener is not isolation from
other processes running as that user.

## Development

```bash
npm test
npm start
```
