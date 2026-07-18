# relay-auth

A Cloudflare Worker that holds YNAB's and Splitwise's OAuth `client_secret`
so the Relay app itself doesn't have to. See the comment at the top of
[src/index.ts](src/index.ts) for why this exists.

The app still runs the whole browser-based sign-in step itself
(`ASWebAuthenticationSession`) and gets back an authorization `code`; it
just calls this Worker instead of the provider's `/oauth/token` endpoint
directly to exchange that code (or a stored `refresh_token`) for tokens.
This Worker adds `client_id`/`client_secret`/`redirect_uri` and forwards
the request, then relays the provider's JSON response back unchanged.

## Endpoints

All are `POST`, JSON body in, JSON body out (whatever the provider
returned — success shape is `{access_token, refresh_token, expires_in}`,
errors are the provider's own OAuth error shape).

| Endpoint | Body |
|---|---|
| `/ynab/token` | `{code, code_verifier}` |
| `/ynab/refresh` | `{refresh_token}` |
| `/splitwise/token` | `{code}` |
| `/splitwise/refresh` | `{refresh_token}` |

## One-time setup

```sh
npm install
npx wrangler login          # opens a browser to authorize wrangler against your Cloudflare account
npx wrangler secret put YNAB_CLIENT_SECRET
npx wrangler secret put SPLITWISE_CLIENT_SECRET
npx wrangler deploy
```

Deployed at `https://relay-auth.octabits.net` (a Custom Domain, configured
via `routes` in [wrangler.jsonc](wrangler.jsonc) — requires `octabits.net`
to already be an active zone on this Cloudflare account). That URL is
already set in `Relay/Auth/OAuthConfig.swift`'s `oauthRelayBaseURL`; update
it there if you ever change the domain.

### Setting the secrets

Client secrets no longer live in the app's source at all — the
authoritative place to view or rotate them is each provider's own OAuth
app dashboard:

- YNAB: https://app.ynab.com/settings/developer → your OAuth application
- Splitwise: https://secure.splitwise.com/apps → your app

Run `wrangler secret put <NAME>` yourself, once per secret, rather than
scripting it — the value should be typed directly into wrangler's prompt,
never passed as a command-line argument, piped through `echo`, or
committed anywhere:

```sh
npx wrangler secret put YNAB_CLIENT_SECRET
# ✔ Enter a secret value: › (paste the YNAB client secret, then Enter)
# 🌀 Creating the secret for the Worker "relay-auth"
# ✨ Success! Uploaded secret YNAB_CLIENT_SECRET

npx wrangler secret put SPLITWISE_CLIENT_SECRET
# same prompt, paste the Splitwise client secret
```

A secret takes effect immediately — no redeploy needed. To update a secret
later (rotation, or fixing a typo), just run `wrangler secret put` again
with the same name; to remove one, `wrangler secret delete <NAME>`. Use
`wrangler secret list` to see which names are set (it only shows names,
never values).

`YNAB_CLIENT_ID` / `YNAB_REDIRECT_URI` / `SPLITWISE_CLIENT_ID` /
`SPLITWISE_REDIRECT_URI` are plain (non-secret) `vars` in
[wrangler.jsonc](wrangler.jsonc) — fine to commit, since a client ID and a
redirect URI aren't confidential per OAuth's spec.

## Local development

```sh
npm run dev
```

Local dev has no secrets configured unless you also create a `.dev.vars`
file (gitignored) with `YNAB_CLIENT_SECRET=...` /
`SPLITWISE_CLIENT_SECRET=...` — without it, token exchanges will fail with
`invalid_client`, which is expected.

## After changing wrangler.jsonc

```sh
npm run types   # regenerates worker-configuration.d.ts
```
