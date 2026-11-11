# Sessions, CSRF, and JWT

Browser login state, CSRF protection, and bearer-token verification.

[Back to the documentation index](../README.md)

## Sessions

`weft.session` provides a bounded in-memory session store and middleware.
Session values are copied into the request arena for the handler chain and
written back to the store afterwards, so handlers never hold a pointer into
shared state.

```zig
var store = try weft.session.Store.init(gpa, .{
    .max_sessions = 4096,
    .max_bytes_per_session = 16 * 1024,
    .idle_timeout = .fromSeconds(24 * 60 * 60),
    .absolute_timeout = .fromSeconds(7 * 24 * 60 * 60),
});
defer store.deinit();

var sessions = weft.session.Middleware{
    .store = &store,
    .options = .{
        .cookie_name = "weft_session",
        .secure = true, // set when the listener terminates TLS
        .same_site = .lax,
    },
};
try router.get("/", home, .{ .middleware = &.{sessions.handler()} });
```

Handlers use the request-local view:

```zig
fn login(_: *App, ctx: *weft.Ctx) anyerror!void {
    const session = weft.session.from(ctx) orelse
        return error.MissingSessionMiddleware;
    try session.set("user_id", "42");
    try session.setJson("prefs", .{ .theme = "dark" });

    // Issue a fresh id after a successful login to prevent fixation.
    session.rotate();
    try ctx.text("ok");
}

fn logout(_: *App, ctx: *weft.Ctx) anyerror!void {
    const session = weft.session.from(ctx) orelse return;
    session.destroy();
    try ctx.text("bye");
}
```

`Session.get`, `set`, `remove`, `setJson`, and `getJson` operate on the
request arena. `destroy()` removes the server-side entry and expires the
cookie. `rotate()` moves the session to a fresh id and updates the cookie.

Limits:

- `Store.Options.max_sessions` bounds retained sessions; the oldest entry is
  evicted on overflow.
- `max_bytes_per_session` bounds the sum of key and value bytes.
- `idle_timeout` and `absolute_timeout` are enforced on load.
- Session ids are 32 random bytes encoded as 64 lowercase hex characters.

The built-in store is process-local. Multi-process deployments need a shared
store (Redis/DB) or sticky sessions; the `Store` API is the seam for a future
backend.

## CSRF

`weft.csrf` implements a session-bound synchronizer token with an optional
double-submit cookie for browser clients.

```zig
var csrf = weft.csrf.Middleware{
    .options = .{
        .allowed_origins = &.{"https://app.example.com"},
        .secure = true,
    },
};

const common = [_]weft.Handler{
    sessions.handler(),
    csrf.handler(), // must run after the session middleware
};
```

Behavior:

- Safe methods (`GET`, `HEAD`, `OPTIONS`, `TRACE`) receive a token in the
  session and a non-HttpOnly `weft_csrf` cookie.
- Unsafe methods must echo the token in `x-csrf-token` (configurable with
  `Options.header_name`).
- When `allowed_origins` is non-empty, unsafe requests must also carry an
  exact `Origin` match.
- Missing or invalid tokens receive `403`.

Handlers render the token for forms or JSON:

```zig
const token = weft.csrf.from(ctx).?.value;
```

CSRF protection requires the session middleware; running it without a session
returns `error.CsrfRequiresSession`.

## JWT

`weft.jwt` signs and verifies compact JWS tokens. `hs256` and Ed25519
(`eddsa`) are supported; RSA/ECDSA need an external big-integer verifier.

```zig
const secret = "0123456789abcdef0123456789abcdef";
const token = try weft.jwt.encode(gpa, .{
    .sub = "user-42",
    .iss = "weft",
    .aud = "api",
    .exp = now_seconds + 3600,
}, .{ .key = .{ .hs256 = secret } });

var verified = try weft.jwt.verify(gpa, token, .{
    .key = .{ .hs256 = secret },
    .issuer = "weft",
    .audience = "api",
    .io = io, // used when now_seconds is null
});
defer verified.deinit();

const subject = verified.claimString("sub").?;
```

Verification always:

- rejects unknown or mismatched algorithms (no `alg=none` confusion);
- checks the signature before trusting any claim;
- enforces `exp`, `nbf`, `iss`, and `aud` with optional clock skew;
- optionally requires `exp` and `sub`.

### Bearer middleware

```zig
var bearer = weft.middleware.Bearer{
    .options = .{
        .key = .{ .hs256 = secret },
        .issuer = "weft",
        .audience = "api",
    },
};

try router.get("/me", me, .{ .middleware = &.{bearer.handler()} });

fn me(_: *App, ctx: *weft.Ctx) anyerror!void {
    const claims = weft.middleware.bearer(ctx) orelse
        return error.MissingBearer;
    try ctx.text(claims.claimString("sub").?);
}
```

Missing or invalid credentials receive `401` with `WWW-Authenticate: Bearer`.
`required = false` lets requests without a token continue; an invalid token is
still rejected. `OPTIONS` preflights are skipped by default.

## Security notes

- Set `secure = true` on session and CSRF cookies when serving TLS.
- Use `SameSite=Lax` unless cross-site embedding requires `None`; `None`
  requires `Secure`.
- Rotate the session after login and destroy it on logout.
- CSRF tokens are exposed to JavaScript by design (double-submit); XSS already
  defeats CSRF protection.
- JWTs are signed, not encrypted; never put secrets in the payload. Short
  expiry plus refresh rotation is the practical revocation strategy.
- This slice does not implement OAuth 2.0/OIDC; use an external identity
  provider and issue a session or JWT after the callback.
