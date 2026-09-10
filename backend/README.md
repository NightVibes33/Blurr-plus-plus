# MovieBox guest authentication service

This service implements the server-backed guest-account half of `temp/moviebox-persistent-session`.

## Contract

`POST /v1/guest/bootstrap`

```json
{
  "install_id": "stable-keychain-install-id"
}
```

The same `install_id` is HMACed server-side and always resolves to the same guest user. The raw install identifier is never stored in the database.

Successful response:

```json
{
  "user": {
    "id": "guest_...",
    "username": "guest_...",
    "nickname": "Guest abc123",
    "kind": "guest"
  },
  "session": {
    "access_token": "...",
    "refresh_token": "...",
    "token_type": "Bearer",
    "expires_in": 3600
  }
}
```

`POST /v1/guest/refresh` rotates the refresh token and returns a new access token.

## Persistence

Guest identity is persisted in SQLite. A reinstall that retains the Keychain installation ID resolves to the same guest user. Normal app restarts do not create new users.

## Run

```bash
cd backend
npm install
SESSION_SECRET="replace-with-a-long-random-secret" npm start
```

Optional environment variables:

- `PORT` (default `8787`)
- `DATA_PATH` (default `./guest-auth.sqlite3`)
- `ACCESS_TTL_SECONDS` (default `3600`)
- `REFRESH_TTL_SECONDS` (default `7776000`, 90 days)

## Important integration boundary

Tokens issued here are valid for this guest-auth service. The existing MovieBox API must explicitly trust or exchange these guest tokens before protected MovieBox endpoints can treat the guest as authenticated.

The compiled IPA does not expose a safe way to make that trust decision locally. Do not copy a master account token into the client, fabricate Google credentials, or locally force VIP/account flags; those approaches create inconsistent server state and are not a valid guest-account implementation.
