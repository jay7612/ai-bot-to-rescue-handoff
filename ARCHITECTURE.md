# Architecture

Detailed technical walkthrough of how the integration works.

## High-level flow

```
   ┌─────────────────────────────────────────┐
   │  AI bot fails to self-heal              │
   │  (Spark / ServiceNow VA / Copilot)      │
   └─────────────────┬───────────────────────┘
                     │ HTTP POST (webhook)
                     ▼
   ┌─────────────────────────────────────────┐
   │  Webhook receiver                       │
   │  Node-RED on Pi via ngrok tunnel        │
   └─────────────────┬───────────────────────┘
                     │
       ┌─────────────┴─────────────┐
       │                           │
       ▼                           ▼
   200 ack to bot         Main work branch
   (immediate)            (runs async)
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │  OpenAI summarization         │
                  │  gpt-5.4-mini, <=500 chars    │
                  └───────────────┬───────────────┘
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │  Nexthink auth                │
                  │  /api/v1/token                │
                  └───────────────┬───────────────┘
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │  Nexthink NQL                 │
                  │  device name → collector.uid  │
                  └───────────────┬───────────────┘
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │  Nexthink remote action       │
                  │  /api/v1/act/execute          │
                  └───────────────┬───────────────┘
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │  PowerShell on endpoint       │
                  │  - writes CFields to HKCU     │
                  │  - launches Calling Card      │
                  └───────────────┬───────────────┘
                                  │
                                  ▼
                  ┌───────────────────────────────┐
                  │  Rescue technician connects   │
                  │  with AI summary in context   │
                  └───────────────────────────────┘
```

## Node-RED flow walkthrough

The flow has 14 nodes organized in roughly four sections.

### Section 1 — Webhook receiver and ack

| Node | Purpose |
|---|---|
| `Nexthink/AI Bot Listener` | HTTP-in node listening on POST `/nexthink/rescue` |
| `Extract Payload` | Pulls `cmdb_ci`, `caller_id`, `description`, `work_notes` etc. from the bot's JSON body |
| `Build Ack` | Generates synthetic `ticketId` and `ticketNumber` so the bot can show the user a reference |
| `200 OK` | http-response node — closes the request immediately |

The ack and the main work branch fan out from `Extract Payload` in parallel. The bot gets a 200 response in <50ms; the rescue trigger work continues in the background for several seconds.

### Section 2 — AI summarization

| Node | Purpose |
|---|---|
| `Validate Input` | Fail-fast if `cmdb_ci` is missing |
| `Build AI Request` | Combines `description` + `work_notes`, builds OpenAI Responses API call. Sets `skipAI=true` if content is already ≤500 chars |
| `Skip AI?` | Switch node — routes around OpenAI if not needed |
| `Call OpenAI` | http-request to `/v1/responses` |
| `Parse Summary` | Extracts the summary text from the Responses API output shape; falls back to truncated raw text if anything fails |

The fallback is intentional: if OpenAI is slow, errors out, or returns garbage, the flow continues with a truncated raw description rather than blocking the rescue. The rescue session is the critical piece; the summary is a nice-to-have.

### Section 3 — Nexthink calls

| Node | Purpose |
|---|---|
| `Get Auth Token` | POST to `/api/v1/token` with Basic auth |
| `Extract Token` | Pull `access_token` from response |
| `Build NQL Request` | Build the NQL query payload — IMPORTANT: parameter key is `param0`, not the parameter name from the NQL query body |
| `Call NQL` | POST to `/api/v2/nql/execute` |
| `Parse UID` | Extract `device.collector.uid` from `body.data[0]` and overwrite `msg.deviceName` with the resolved UUID |

The NQL lookup exists because the AI bot (Spark in this case) sends a device hostname (e.g. `SC-WIN11-0002`), but the Nexthink Execute API requires the device's `collector.uid` (a UUID). The saved NQL query `#resolve_device_uid_by_name` does the translation.

### Section 4 — Remote action and response

| Node | Purpose |
|---|---|
| `Build Execute Payload` | Build the execute payload with `params.IssueSummary` containing the AI summary |
| `Execute Remote Action` | POST to `/api/v1/act/execute` |
| `Handle Response` | Parse the requestId for logging |

### Error handling

A `Catch Errors` node listens for `node.error()` from any node in the flow and routes failures to a `Flow Errors` debug node. In production, this should route to your alerting system instead.

## Hard-won gotchas

If you're adapting this for a different chatbot or a different ITSM tool, these are the non-obvious things that cost time to debug:

1. **The webhook receiver path lives in two places** — the Node-RED http-in node holds just the path (`/nexthink/rescue`); the bot's webhook config holds the full URL including the path. They must match exactly.

2. **Nexthink connector credentials vs API calls** — Nexthink splits the base URL (in the connector credential) from the path (in the API call). Putting the full URL in the API call's Resource field results in the base getting concatenated, producing a self-embedded URL that 404s.

3. **Nexthink NQL parameter naming is positional** — you might declare `$deviceName` in the query body, but the API call expects `param0` as the key in the parameters object. Same for `param1`, `param2`, etc.

4. **Nexthink NQL response shape uses `data[]` not `rows[]`** — `rows` is just an integer count. Actual data is in `data` as an array of row objects keyed by column name.

5. **Spark sends device hostname, not UUID** — even though the Cmdb ci field in Spark's Manage Settings says "Device → Name" or "Device → UID", the actual value Spark sends through is the hostname. NQL lookup is required.

6. **Spark expects `ticketId` and `ticketNumber` in the response** — case-sensitive, exact strings. Without these in the response and in the API Call's Output tab JSONata config, Spark treats the escalation as failed and falls back to "submit manually."

7. **The `params` field in the Execute payload is an object**, not an array of `{name, value}` objects. The key in the object must match the parameter name in the Nexthink Remote Action config AND the PowerShell `param()` block.

## PowerShell on the endpoint

The remote action runs a PowerShell script that:

1. Discovers which Rescue Calling Card is installed by enumerating subkeys under `HKLM:\SOFTWARE\Wow6432Node\LogMeInRescueCallingCards`. The subkey name *is* the referralId.

2. Locates the calling card executable from the registry's `InstallDir` value — avoids hardcoded paths.

3. Writes CField values to `HKCU:\Software\LogMeInRescueCallingCards\<referralId>`:
   - `CField0` = machine name (auto)
   - `CField1` = current user (auto)
   - **`CField2` = AI issue summary** (this is the value shown as "Reason for reaching out" in the Rescue tech UI)
   - `CField3` = local IP
   - `CField4` = "Spark escalation" (or whichever bot source)
   - `CField5` = workflow tag

4. Launches `CallingCard.exe -silent -channel`.

**The script must run as the interactive logged-in user**, not SYSTEM. CField values live under HKCU, and SYSTEM has its own HKCU hive that the calling card won't read. This is configured on the Nexthink Remote Action's "Run as" setting.

## What's not in this repo

A few things were intentionally left out:

- **Authentication on the webhook receiver.** For a POC behind ngrok this is fine; for production you'd add HMAC verification or a shared secret check before `Extract Payload`.
- **Retry logic.** Network calls in the flow don't retry. In production, especially for the OpenAI call (which can have intermittent latency), you'd add retry with exponential backoff.
- **Observability.** Logs go to Node-RED's debug sidebar. In production, you'd ship them to a real logging stack.
- **Secret rotation.** Env vars on systemd work for a POC. In production, secrets go in a vault with rotation policies.

These are all reasonable Phase 3 work.
