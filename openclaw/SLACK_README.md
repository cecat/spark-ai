# OpenClaw Slack Integration

## One App, Multiple Agents

A single Slack app serves all agents managed by one OpenClaw gateway. You do not create separate Slack apps per agent. Instead, you configure one app with one bot token, and use OpenClaw's `bindings` and `channels` config to route different conversations to different agents. In the example below, the `main` agent handles all DMs by default, while `chattpc26` handles a specific Slack channel. You can extend this pattern to any number of agents and channels.

---

## Step 1: Create the Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App → From scratch**
2. Name it (e.g. `ChatCeC`), select your workspace, click **Create App**

---

## Step 2: Enable Socket Mode

1. Go to **Socket Mode** in the left sidebar and toggle it **On**
2. When prompted, create an App-Level Token — name it `openclaw`, scope `connections:write`
3. Copy the `xapp-...` token — this is your **App Token**

---

## Step 3: Add Bot Token Scopes

Go to **OAuth & Permissions → Bot Token Scopes** and add exactly these scopes:

| Scope | Purpose |
|---|---|
| `app_mentions:read` | Respond to @mentions in channels |
| `channels:history` | Read public channel messages |
| `channels:read` | View public channel info |
| `chat:write` | Send messages |
| `files:read` | Read shared files |
| `files:write` | Upload files |
| `groups:history` | Read private channel messages |
| `im:history` | Read DM messages |
| `im:read` | View DM metadata |
| `im:write` | Open DM conversations |
| `mpim:history` | Read group DM messages |
| `reactions:read` | View emoji reactions |
| `reactions:write` | Add emoji reactions |
| `users:read` | View workspace members |

> ⚠️ **Do NOT add `assistant:write`** — this enables Slack's native AI agent streaming API which causes messages to silently fail with `missing_recipient_team_id` errors.

---

## Step 4: Subscribe to Bot Events

Go to **Event Subscriptions**, toggle **On**, then under **Subscribe to bot events** add:

- `app_mention`
- `message.channels`
- `message.groups`
- `message.im`
- `message.mpim`

---

## Step 5: Enable Messages Tab

Go to **App Home → Show Tabs** and toggle **Messages Tab** on. Check **Allow users to send Slash commands and messages from the messages tab**.

---

## Step 6: Install the App

Go to **Install App → Install to Workspace**, approve, and copy the `xoxb-...` **Bot Token**.

---

## Step 7: Configure OpenClaw

### openclaw.json — channels section

```json
"channels": {
  "slack": {
    "mode": "socket",
    "webhookPath": "/slack/events",
    "enabled": true,
    "botToken": "xoxb-...",
    "appToken": "xapp-...",
    "groupPolicy": "allowlist",
    "streaming": false,
    "dmPolicy": "pairing",
    "dm": {
      "enabled": true
    },
    "channels": {
      "C09KGGMS116": {
        "allow": true,
        "requireMention": true
      }
    }
  }
},
```

> Note: `streaming: false` prevents use of Slack's native streaming API, which is unreliable without the `assistant:write` scope. Messages still deliver normally.

> Note: `webhookPath` is for HTTP mode only — but omitting it generated a config error...

> Note: `groupPolicy: "allowlist"` requires every channel the bot should respond in to be listed under `channels`. An empty allowlist means the bot responds nowhere. The channel number comes from the ID in the link to the channel (in Slack, when you right-click to get a link to the channel).

### openclaw.json — agents and bindings section

Note in this example you may be using a different model - this is from a system running vllm/Qwen...

```json
"agents": {
  "defaults": {
    "model": { "primary": "vllm/Qwen/Qwen3-Coder-Next-FP8" },
    "workspace": "/home/node/agents/main"
  },
  "list": [
    {
      "id": "main",
      "workspace": "/home/node/agents/main",
      "default": true
    },
    {
      "id": "chattpc26",
      "workspace": "/home/node/agents/chattpc26"
    }
  ]
},
"bindings": [
  {
    "match": {
      "channel": "slack",
      "peer": { "kind": "channel", "id": "C09KGGMS116" }
    },
    "agentId": "chattpc26"
  }
],
```

**How routing works:**
- DMs to the bot → `main` agent (default)
- Messages in channel `C09KGGMS116` → `chattpc26` agent (via binding)
- Any other allowed channel → `main` agent (default fallback)

To find a channel's ID: open Slack, go to the channel, click the channel name at the top — the ID appears at the bottom of the info panel (format: `C` followed by alphanumeric characters).

---

## Step 8: Pair Your Account

After saving the config and seeing `[slack] socket mode connected` in the gateway logs, open a DM with your bot in Slack. It will send you a pairing code. Approve it on the server:

```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli pairing approve slack <CODE>
```

---

## Step 9: Invite the Bot to Channels

For each channel where an agent should respond, invite the bot:

```
/invite @ChatCeC
```

Then @mention it to trigger a response: `@ChatCeC hello`

---

## Troubleshooting

**Gateway keeps restarting**
Check `gateway.auth.mode` — if set to `"password"`, a `"password"` field is required. Use `"token"` mode with a `"token"` field instead.

**"Sending messages to this app has been turned off"**
Go to **App Home → Messages Tab** and ensure it is enabled with "Allow users to send messages" checked. Reinstall the app after making changes.

**Agent shows thinking but never delivers a message**
Set `"streaming": false` in the slack config section. Do not add `assistant:write` scope.

**`missing_scope` warning in logs**
The bot cannot resolve channel names from IDs — cosmetic only, does not affect functionality. Use channel IDs directly in config rather than names.

**Agent not responding in a channel**
Check that the channel ID is listed under `channels.slack.channels` with `"allow": true`, and that the bot has been invited to the channel with `/invite @BotName`.

**Config invalid when saving**
`channels` under `slack` must be an object keyed by channel ID, not an array. Correct: `"channels": { "C123": { "allow": true } }`. Wrong: `"channels": ["C123"]`.
