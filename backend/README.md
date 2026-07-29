# Noikar Authentication API

The Godot client uses this API to create accounts, sign in, and prove the
account identity to a dedicated ENet server before the server spawns a player.

## Local Run

1. Start PostgreSQL with `docker compose up -d` from this directory.
2. Export the values from `.env.example` with a real `JWT_SECRET` of at least
   32 characters.
3. Run `go run ./cmd/server`.

The API listens on `http://127.0.0.1:8080` by default. Set Godot's
`noikar/auth/api_url` project setting to the deployed HTTPS URL outside local
development.

## Contract

- `POST /api/v1/auth/register` accepts `username` and `password` and returns
  `token`, `account_id`, and `username`.
- `POST /api/v1/auth/login` has the same response shape.
- `GET /api/v1/auth/me` requires `Authorization: Bearer <token>`.

Passwords are bcrypt hashes in PostgreSQL. The dedicated server validates the
token with `/auth/me`; it never receives the JWT signing secret.
