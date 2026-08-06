# Serving Stack and Delivery

Throughput work is not finished when the engine is fast. Between the weights and
the user sit several hops, each able to silently drop a capability — and the
symptom is almost never an error.

## Validate the capability end to end, at every hop

```
weights  ->  engine flags  ->  gateway / proxy  ->  client
```

Test each hop separately, with the same payload:

```bash
# 1. engine, direct
curl -s "$ENGINE/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"'"$M"'","messages":[...],"tools":[...],"tool_choice":"auto"}'

# 2. identical request through the gateway
curl -s "$PROXY/v1/chat/completions" -H "Authorization: Bearer $KEY" -d '...'

# 3. the real client, in the mode it actually uses
```

A capability confirmed at hop 1 tells you **nothing** about hop 3. When something
works direct and fails in the app, bisect by hop before touching the model.

## The engine needs explicit feature flags

Tool calling and reasoning extraction usually require parser flags. Without them
a tools payload is rejected outright (400) or comes back as prose *describing*
the call it would make:

```
--enable-auto-tool-choice --tool-call-parser <name> --reasoning-parser <name>
```

Parser names are version-specific and not guessable. A plausible name taken from
the model card was rejected; the accepted spelling was different and shorter.
**Get the valid set from the argument validator's own error message**, not from
documentation written for another release.

Confirm with a real tool payload and check `finish_reason` — a correct result is
`finish_reason: "tool_calls"` with populated `tool_calls`, not prose that
mentions the function name.

## Test streaming and non-streaming separately

They take different paths through the parser and genuinely behave differently:

- **Non-streaming can drop reasoning content entirely** — generated, billed in
  `completion_tokens`, then discarded (13.7K tokens vanished in one measured run).
- **Streaming may deliver it under a different field name** than the
  non-streaming response documents.
- **Tool-call assembly differs**: streaming emits incremental fragments the
  client must join; a client that mishandles them sees no tool call at all.

Agent frameworks are almost always streaming. Validate the mode your client uses,
not the one that is convenient to curl.

## Gateways strip parameters silently

A proxy between agent and engine may drop unknown parameters for compatibility.
If it does not know the model supports function calling, `tools` and `tool_choice`
can be removed before forwarding. The engine sees no tools, answers in prose, and
the agent stops after one turn having done nothing.

**The symptom is "the agent replies and takes no action" — not an error.**

- Bypass the proxy and retry directly. Works direct, fails proxied → the proxy.
- Declare model capabilities explicitly in the gateway config instead of relying
  on defaults or auto-detection for a self-hosted model id.
- **Keep the upstream model id in sync.** A route pointing at a model name the
  server no longer serves fails at request time, long after the config was
  written — this breaks silently when you re-serve a different checkpoint on the
  same endpoint.

## Load balancing replicas can destroy prefix-cache locality

Each engine replica holds its **own** prefix cache in its own KV pool. Nothing is
shared between them. So a gateway that spreads requests across replicas by load,
latency or round-robin is making a **performance** decision, not just an
availability one.

Why it matters: agent traffic resends a long, growing conversation every turn, so
the shared prefix is nearly the whole prompt. One measured deployment sustained a
**79.4% prefix-cache hit rate** precisely because each conversation kept landing
on the same replica. Read yours from the engine:

```
vllm:prefix_cache_queries_total
vllm:prefix_cache_hits_total
```

The value at stake is the gap between cached and cold prefill. Measured on one
deployment: **~2,000 tok/s cold versus ~7,400 tok/s** with cache hits — a 3.6x
swing on time-to-first-token for a large prompt. With two replicas and no
affinity, a conversation's next turn lands on the cold replica about half the
time.

Check before you scale out horizontally:

- Does the router support **session affinity or prefix-aware routing**? Common
  strategies (round-robin/shuffle, least-busy, lowest-latency, cost-based) are
  all cache-blind. A router that cannot pin a conversation to a replica will
  trade your hit rate for its balance.
- If it cannot, prefer **separate endpoints** clients choose deliberately, or a
  routing plugin that hashes a stable session key to one replica. Perfect
  locality on one replica can beat balanced traffic across two.
- Measure it rather than assuming: compare hit rate before and after adding the
  second replica. A throughput win that halves the hit rate can be a net loss on
  prefill-heavy workloads.

Latency-based routing is the least-bad cache-blind option when one replica is
local and another is remote: it naturally prefers the near replica and spills
only under load, which incidentally preserves locality.

## Served limits are not the model's limits

The checkpoint advertises an architectural maximum; the deployment enforces
whatever fits in its KV pool:

```
config.json:  max_position_embeddings = 1048576   # 1M, architectural
/v1/models:   max_model_len           = 350000    # what this server accepts
```

Clients that read the model card or `config.json` will present the larger number
and happily let a user exceed the served limit, which fails as a hard 400 at
request time — after the user has assembled the context.

- Treat `/v1/models` → `max_model_len` as the source of truth, and configure
  clients from it rather than from the model card.
- When publishing an endpoint, publish the **served** limit next to it.
- Do not assume a model card's context length is achievable on your hardware. For
  a model that fills its GPUs it usually is not; see
  [memory-budget.md](memory-budget.md).

## Budget for reasoning tokens in agent loops

Reasoning models spend output budget thinking before acting. With a small
`max_tokens`, a request can be truncated mid-thought and return **empty content
and no tool call** — indistinguishable at a glance from "the model chose to do
nothing".

Before concluding a model cannot drive an agent, check `finish_reason` and
`completion_tokens`. `length` with a full budget spent means it was cut off, not
incapable. Compressed checkpoints make this worse: measure the truncation rate
(see the pruned-checkpoint section of [memory-budget.md](memory-budget.md)).
