# Codex model proxy

This localhost-only Responses API router lets Codex CLI and Codex Desktop use
OpenAI/ChatGPT models and the Brev-hosted Webster models from one provider.

Install and configure it from the repository root with `codex-setup.sh`. The
source files in this directory are downloaded to `~/.codex/model-proxy` by the
installer; there are no npm dependencies.

## Security

- The server binds to `127.0.0.1` by default.
- OpenAI credentials are forwarded only to OpenAI or the ChatGPT Codex backend.
- The incoming OpenAI credential and ChatGPT account header are removed before
  a Webster request, which receives only the Webster key.
- Request bodies, response bodies, credentials, and headers are not logged.
- `~/.codex/model-proxy/webster.json` is written with mode `0600`.

Any process running as the same OS user can already read that user's Codex and
Webster credential stores; the loopback listener is not isolation from other
processes running as that user.

## Development

```bash
npm test
npm start
```
