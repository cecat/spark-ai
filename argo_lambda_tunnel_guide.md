# Argo Proxy / Lambda5 Tunnel Setup Guide

> **OBSOLETE (kept for historical reference, 2026-05-22).** Lambda5 was taken down and the workflow described below — manual SSH jump tunnels through `lambda5.cels.anl.gov` — is no longer how this system reaches Argo. The current path is:
>
> - `argo-shim` (a Python proxy at `~/.local/bin/argo-shim`) listens on `127.0.0.1:44497`
> - it self-manages its own `ssh -L 127.0.0.1:44496:apps.inside.anl.gov:443` jump through `logins`/`homes` via `ControlPersist`
> - `socat` bridges `172.18.0.1:44497` (the `nim_net` Docker bridge) to `127.0.0.1:44497` so the OpenClaw gateway and sandbox containers can reach the shim
> - `start-all.sh` brings up all four components (vLLM, argo-shim, socat, gateway) idempotently
>
> Read the rest of this file only if you need historical context on the old setup or are debugging a similar SSH-tunnel scenario from scratch.

---

This is an updated version of the original “Setting Up Argo Proxy Access on a Home Spark” guide, updated to reflect a working setup and a few failure modes that are easy to misinterpret.

It is written for a Linux or macOS machine outside the Argonne network that needs to reach the Argo model gateway on `lambda5.cels.anl.gov` through SSH jump hosts.

## Table of Contents

1. [What this gives you](#1-what-this-gives-you)
2. [Prerequisites](#2-prerequisites)
3. [Step 1: Create a CELS SSH key and register it in the CELS portal](#3-step-1-create-a-cels-ssh-key-and-register-it-in-the-cels-portal)
4. [Step 2: Load the key into ssh-agent](#4-step-2-load-the-key-into-ssh-agent)
5. [Step 3: Configure `~/.ssh/config`](#5-step-3-configure-sshconfig)
6. [Step 4: Verify the hop chain correctly](#6-step-4-verify-the-hop-chain-correctly)
7. [Step 5: Start the background tunnel](#7-step-5-start-the-background-tunnel)
8. [Step 6: Verify the local tunnel](#8-step-6-verify-the-local-tunnel)
9. [Step 7: Use the API](#9-step-7-use-the-api)
10. [Troubleshooting](#10-troubleshooting)
11. [Quick reference](#11-quick-reference)

---

## 1. What this gives you

Once working, your local machine will expose an OpenAI-compatible endpoint at:

```bash
http://localhost:44497/v1
```

The SSH chain is:

```text
Your machine -> logins.cels.anl.gov -> homes.cels.anl.gov -> lambda5.cels.anl.gov -> Argo gateway
```

---

## 2. Prerequisites

You need all of the following:

- a CELS account
- Argonne / CELS credentials that can authenticate through the jump hosts
- internet access to `logins.cels.anl.gov` on port 22
- membership in the **Lambda** project in the CELS account portal
- a local SSH key dedicated to this access path

---

## 3. Step 1: Create a CELS SSH key and register it in the CELS portal

Do **not** rely on the old `id_rsa.pub` naming from older SSH tutorials unless you have a specific reason to do so.

Use a clearly named dedicated key instead, for example:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519_cels -C "$(hostname) CELS tunnel"
```

This creates:

- private key: `~/.ssh/id_ed25519_cels`
- public key: `~/.ssh/id_ed25519_cels.pub`

Why this is better:

- it avoids colliding with an existing `~/.ssh/id_rsa` or `~/.ssh/id_rsa.pub`
- it makes it obvious what the key is for
- `ed25519` is a good modern default and worked correctly in the tested setup

Now go to:

```text
https://accounts.cels.anl.gov
```

In that portal, do **both** of these:

1. Upload your public key `~/.ssh/id_ed25519_cels.pub`
2. Request membership in the **Lambda** project

Both matter. Uploading the key alone is not enough if your account is not also enabled for Lambda access.

---

## 4. Step 2: Load the key into ssh-agent

If your key has a passphrase, load it into `ssh-agent` so you do not have to type the passphrase every time.

### Linux

Run once in the current shell:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519_cels
```

To auto-start for future shells, add this to `~/.bashrc` or `~/.zshrc`:

```bash
if [ -z "$SSH_AUTH_SOCK" ]; then
  eval "$(ssh-agent -s)" > /dev/null
fi
ssh-add -l >/dev/null 2>&1 || ssh-add ~/.ssh/id_ed25519_cels 2>/dev/null
```

### macOS

Run once:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_cels
```

Then add this near the top of `~/.ssh/config`:

```sshconfig
AddKeysToAgent yes
IgnoreUnknown UseKeychain
UseKeychain yes
```

---

## 5. Step 3: Configure `~/.ssh/config`

Add the following entries, replacing `YOUR_USERNAME` with your CELS username.

```sshconfig
Host logins
    HostName logins.cels.anl.gov
    User YOUR_USERNAME
    IdentityFile ~/.ssh/id_ed25519_cels
    IdentitiesOnly yes

Host homes
    HostName homes.cels.anl.gov
    User YOUR_USERNAME
    IdentityFile ~/.ssh/id_ed25519_cels
    IdentitiesOnly yes
    ProxyJump logins

Host argo-tunnel
    HostName lambda5.cels.anl.gov
    User YOUR_USERNAME
    IdentityFile ~/.ssh/id_ed25519_cels
    IdentitiesOnly yes
    ProxyJump homes
    LocalForward 44497 127.0.0.1:44497
    LocalForward 44496 127.0.0.1:44496
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
```

Optional but handy for direct testing:

```sshconfig
Host lambda5
    HostName lambda5.cels.anl.gov
    User YOUR_USERNAME
    IdentityFile ~/.ssh/id_ed25519_cels
    IdentitiesOnly yes
    ProxyJump homes
```

Why the `IdentityFile` lines matter:

- they force SSH to use the intended CELS key
- they avoid confusing fallback behavior when you have several keys
- they make `ssh -vvv` output much easier to interpret

---

## 6. Step 4: Verify the hop chain correctly

This is the part that confused the original guide most.

### Important: do not use `ssh logins hostname` as your only success test

This command may produce output like this:

```text
Success. Logging you in...
This account is currently not available.
```

That looks like a contradiction, and to a normal human it reasonably looks like failure.

In practice, it can mean:

- authentication to `logins` succeeded
- Duo succeeded
- but `logins` is not giving you a normal interactive shell or command session

So for this workflow, the **real** verification is whether `logins` works as a **jump host** to `homes` and `lambda5`.

Use these tests instead.

### Test 1: Can `logins` jump to `homes`?

```bash
ssh -J logins YOUR_USERNAME@homes.cels.anl.gov hostname
```

Expected result: something like:

```text
homes-01
```

### Test 2: Can you reach `lambda5` through both jump hosts?

```bash
ssh -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov hostname
```

Expected result:

```text
lambda5
```

### Test 3: Is the Argo service alive on `lambda5`?

```bash
ssh -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov \
  "curl -s http://localhost:44497/v1/models | head -5"
```

Expected result: JSON beginning with something like:

```json
{"object": "list", "data": ...}
```

If the command prompts for a password on `lambda5`, that is not automatically a failure. If you enter the password and the command returns model JSON, the test succeeded.

### Important SSH syntax note

This is correct:

```bash
ssh -J logins YOUR_USERNAME@homes.cels.anl.gov hostname
```

Here, `hostname` is a command executed **on the remote host after login succeeds**.

This is **not** a test of the next hop:

```bash
ssh -J logins YOUR_USERNAME@homes.cels.anl.gov lambda5
```

That tells `homes` to run the command `lambda5`; it does **not** mean “now SSH onward to lambda5.”

---

## 7. Step 5: Start the background tunnel

Once the three verification tests above work, start the tunnel:

```bash
ssh -f -N argo-tunnel
```

What the flags mean:

- `-f` = go to background after authentication
- `-N` = do not run a remote shell, only do port forwarding

If your key is not already loaded in `ssh-agent`, you may be prompted for:

- your key passphrase
- Duo on the `logins` hop
- possibly a password on `lambda5`

---

## 8. Step 6: Verify the local tunnel

Check that something is listening locally:

```bash
lsof -i :44497 | grep LISTEN
```

Then verify the forwarded API endpoint:

```bash
curl -s http://localhost:44497/v1/models | python3 -m json.tool | head -30
```

If that returns a model list, the tunnel is working.

---

## 9. Step 7: Use the API

### Curl example

```bash
curl http://localhost:44497/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "argo:gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Python example

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:44497/v1",
    api_key="YOUR_USERNAME",
)

response = client.chat.completions.create(
    model="argo:gpt-4o",
    messages=[{"role": "user", "content": "Hello!"}],
)

print(response.choices[0].message.content)
```

---

## 10. Troubleshooting

### A. `ssh logins hostname` says `This account is currently not available.`

This is the misleading case.

It does **not** necessarily mean the tunnel setup is broken.

It can mean:

- your authentication to `logins` worked
- Duo worked
- but `logins` is not providing a normal shell or command session

Do **not** stop here. Instead, test the actual jump chain:

```bash
ssh -J logins YOUR_USERNAME@homes.cels.anl.gov hostname
ssh -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov hostname
ssh -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov \
  "curl -s http://localhost:44497/v1/models | head -5"
```

### B. `Permission denied (publickey)` at `logins`

Likely causes:

- you uploaded the wrong public key
- your `~/.ssh/config` points at the wrong private key
- you forgot `IdentityFile` and `IdentitiesOnly yes`
- the key has not propagated yet in the CELS system

Check with:

```bash
ssh -vvv logins
```

Look for lines showing which key SSH actually offered.

### C. You can reach `logins`, but `homes` or `lambda5` still fails

First confirm in `https://accounts.cels.anl.gov` that:

- your public key is uploaded
- your account has membership in the **Lambda** project

If those are correct, run:

```bash
ssh -vvv -J logins YOUR_USERNAME@homes.cels.anl.gov hostname
ssh -vvv -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov hostname
```

These are the best commands to send to support if you need help.

### D. You get prompted for a password on `lambda5`

That is not automatically a problem.

If you then get:

- `lambda5` from the `hostname` test, or
- JSON from the `/v1/models` test,

then the hop succeeded.

### E. `Address already in use` on port 44497

A stale SSH process is still holding the port.

Find it:

```bash
lsof -i :44497 | grep ssh
```

Kill it and restart the tunnel:

```bash
pkill -f "ssh.*argo-tunnel"
ssh -f -N argo-tunnel
```

### F. `curl http://localhost:44497/v1/models` says connection refused

The local tunnel is not running.

Restart it:

```bash
ssh -f -N argo-tunnel
```

Then check again:

```bash
lsof -i :44497 | grep LISTEN
curl -s http://localhost:44497/v1/models | python3 -m json.tool | head -30
```

### G. The tunnel comes up, then later dies

Try all of the following:

- keep `ServerAliveInterval 60`
- keep `ServerAliveCountMax 3`
- if your network is especially aggressive about idle sessions, try lowering `ServerAliveInterval` to `15`

### H. Best verbose debug commands

Use these when asking for help:

```bash
ssh -vvv -J logins YOUR_USERNAME@homes.cels.anl.gov hostname
ssh -vvv -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov hostname
ssh -vvv -N argo-tunnel
```

---

## 11. Quick reference

### Start tunnel

```bash
ssh -f -N argo-tunnel
```

### Check local listener

```bash
lsof -i :44497 | grep LISTEN
```

### List models

```bash
curl -s http://localhost:44497/v1/models | python3 -m json.tool | head -30
```

### Kill stale tunnel

```bash
pkill -f "ssh.*argo-tunnel"
```

### Test hop to `homes`

```bash
ssh -J logins YOUR_USERNAME@homes.cels.anl.gov hostname
```

### Test hop to `lambda5`

```bash
ssh -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov hostname
```

### Test Argo on `lambda5`

```bash
ssh -J logins,homes YOUR_USERNAME@lambda5.cels.anl.gov \
  "curl -s http://localhost:44497/v1/models | head -5"
```

### Test chat completion locally

```bash
curl http://localhost:44497/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "argo:gpt-4o",
    "messages": [{"role": "user", "content": "hi"}]
  }'
```
