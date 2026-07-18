/**
 * OAuth token-exchange relay for Relay (see ../../CLAUDE.md).
 *
 * Relay is a distributed iOS app, so it can't hold YNAB's/Splitwise's
 * client_secret the way a personal-only build could — anything compiled
 * into the app binary is extractable from any install. This Worker is the
 * only thing that holds either secret (via `wrangler secret put`, never in
 * source). It does nothing but relay a token exchange: the app still runs
 * the whole browser-based authorize step itself and hands this Worker the
 * resulting `code` (plus PKCE `code_verifier` for YNAB) or a stored
 * `refresh_token`; this Worker fills in client_id/client_secret/
 * redirect_uri and forwards the request to the provider, then relays the
 * provider's JSON response back verbatim (that response is exactly the
 * `{access_token, refresh_token, expires_in}` shape the app already
 * expects, so there's nothing to reshape).
 *
 * redirect_uri is enforced server-side from Env rather than trusted from
 * the caller, so a request can't redirect a token exchange anywhere else.
 * Never logs the request body, the upstream response body, or either
 * secret — only method/path/status, matching the "never log tokens"
 * constraint in CLAUDE.md.
 */

const YNAB_TOKEN_URL = "https://app.ynab.com/oauth/token";
const SPLITWISE_TOKEN_URL = "https://secure.splitwise.com/oauth/token";

function jsonError(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function readJSONBody(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await request.json();
    return body && typeof body === "object" ? (body as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function requireString(body: Record<string, unknown>, field: string): string | null {
  const value = body[field];
  return typeof value === "string" && value.length > 0 ? value : null;
}

/** POSTs a form-encoded token request upstream and relays the JSON response as-is. */
async function exchangeToken(url: string, params: Record<string, string>): Promise<Response> {
  const upstream = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params),
  });
  const text = await upstream.text();
  return new Response(text, {
    status: upstream.status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    if (request.method !== "POST") {
      return jsonError("method_not_allowed", 405);
    }

    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    const { success } = await env.RATE_LIMITER.limit({ key: ip });
    if (!success) {
      return jsonError("rate_limited", 429);
    }

    const body = await readJSONBody(request);
    if (!body) {
      return jsonError("invalid_json_body", 400);
    }

    const { pathname } = new URL(request.url);
    console.log(`${request.method} ${pathname}`);

    switch (pathname) {
      case "/ynab/token": {
        const code = requireString(body, "code");
        const codeVerifier = requireString(body, "code_verifier");
        if (!code || !codeVerifier) return jsonError("missing_code_or_code_verifier", 400);
        return exchangeToken(YNAB_TOKEN_URL, {
          client_id: env.YNAB_CLIENT_ID,
          client_secret: env.YNAB_CLIENT_SECRET,
          grant_type: "authorization_code",
          code,
          redirect_uri: env.YNAB_REDIRECT_URI,
          code_verifier: codeVerifier,
        });
      }

      case "/ynab/refresh": {
        const refreshToken = requireString(body, "refresh_token");
        if (!refreshToken) return jsonError("missing_refresh_token", 400);
        return exchangeToken(YNAB_TOKEN_URL, {
          client_id: env.YNAB_CLIENT_ID,
          client_secret: env.YNAB_CLIENT_SECRET,
          grant_type: "refresh_token",
          refresh_token: refreshToken,
        });
      }

      case "/splitwise/token": {
        const code = requireString(body, "code");
        if (!code) return jsonError("missing_code", 400);
        return exchangeToken(SPLITWISE_TOKEN_URL, {
          client_id: env.SPLITWISE_CLIENT_ID,
          client_secret: env.SPLITWISE_CLIENT_SECRET,
          grant_type: "authorization_code",
          code,
          redirect_uri: env.SPLITWISE_REDIRECT_URI,
        });
      }

      case "/splitwise/refresh": {
        const refreshToken = requireString(body, "refresh_token");
        if (!refreshToken) return jsonError("missing_refresh_token", 400);
        return exchangeToken(SPLITWISE_TOKEN_URL, {
          client_id: env.SPLITWISE_CLIENT_ID,
          client_secret: env.SPLITWISE_CLIENT_SECRET,
          grant_type: "refresh_token",
          refresh_token: refreshToken,
        });
      }

      default:
        return jsonError("not_found", 404);
    }
  },
} satisfies ExportedHandler<Env>;
