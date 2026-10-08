# carolina-codes-perl

Instructions for this read-only v1 HTTP API. A Carolina Code Conference Elixir site can rotate onto it.

This repository is a finished Perl API. The implementation is a single `app.pl` on `HTTP::Daemon`. The production image is `perl:5.40-slim`. This tree has no `src/` directory, no Compose file, and no local `openapi.yaml`.

The source of truth for routes and payloads is the CMS contract: `priv/api/openapi.yaml` and `priv/api/AGENTS.md` in the Phoenix CMS repository (`github.com/brightball/carolina-codes`). Siblings speak ordinary JSON over the v1 REST + SQL-view contract. Leave Ash JSON:API (`application/vnd.api+json`) unimplemented.

This repository is the workspace root. Cloud agents treat this git remote as the whole tree. The Phoenix CMS is a different remote. A sibling directory such as `../elixir` exists only when that remote is attached to the same environment. Do not fold this tree into the CMS git remote.

Registration is best-effort. If `CAROLINA_URL` is unset or the CMS is down, skip the register call and still serve HTTP.

## Agent memory

Read `MEMORY.md` and `DECISIONS.md` before changing behavior.

Perl 5.40 and `HTTP::Daemon` have no framework-native place to store decisions. Use the three files below. A CPAN `Changes` file is a release changelog, and it does not replace them.

| File | Role |
| --- | --- |
| `AGENTS.md` | Current working instructions. Update it when the way to build, run, or change the API changes. |
| `DECISIONS.md` | Append-only log. Each entry has a date, a status, the decision, and why, including alternatives that were in the tree or that the change replaced. |
| `MEMORY.md` | Short living list of non-obvious facts and gotchas. Edit a fact in place when it stops being true. Do not copy the decision log into it. |

When a choice is already `accepted` in `DECISIONS.md`, follow it. Append a new dated entry when you settle a new choice. To replace an old choice, append the new entry and mark the old status `superseded` by that date. Do not reopen a settled entry by editing its decision away.

## Purpose

The Phoenix app (`Carolina.Polyglot`) keeps at most one language API warm and reads speakers and sponsors from it. With no APIs registered, it falls back to Ash. This process must:

1. Query PostgreSQL `v1_*` views. Leave Ash resource tables alone.
2. Expose the routes in the CMS OpenAPI contract, as implemented in `app.pl`.
3. Register once on boot with the Elixir site. There is no heartbeat. If the site is not running, log and continue. Bind the listener first. Registration runs in a child process and must not sit on the accept path.

## Environment

| Variable | Example | Role |
| --- | --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@127.0.0.1:5432/carolina_dev` | SQL views in the CMS database |
| `CAROLINA_URL` | `http://127.0.0.1:4000` | Elixir site (optional; register no-ops if down) |
| `POLYGLOT_REGISTER_TOKEN` | `dev` | Bearer token for register |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:4006` | URL Elixir will call |
| `PORT` | `4006` locally, `8080` in the image | Listen port |

Handler tests that install a fake catalog need no Postgres. For live HTTP against the views, start Postgres 16 and set the variables above. `app.pl` defaults `PORT` to `4006` when it is unset. The image and `fly.toml` set `PORT=8080`.

See `README.md` for install, run, and quality-gate commands (`make check`, `make hooks`).

## SQL views (query these)

`v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_sponsors`.

The views live in the CMS database. This repo does not ship the view SQL. Year-scoped speaker listings read `v1_speakers` whose slug appears in `v1_talks` for that year, then attach `languages` and `topics` from those talks. Year-scoped sponsor rows read `v1_year_sponsors` and include `tier` and `blurb`. Year-scoped speakers stay on `v1_speakers` and `v1_talks`.

Leave base tables (`speakers`, `organizations`, `talks`, and the rest) out of the public contract. The views are the API. Leave Ash tables alone.

## Required HTTP routes

Wrap list payloads as `{ "data": [ ... ] }` unless noted. An unknown slug returns `404` and `{ "error": "not_found" }`. Any method other than `GET` returns that same 404.

* `GET /health` — liveness `{"ok":true}`. This route does not open a database connection.
* `GET /` — identity (`language`, `language_version`, `api_version`, `framework`, `created_year`, `schema_version`, `endpoints`)
* `GET /v1/years`
* `GET /v1/speakers` and `GET /v1/speakers?year=2025`
* `GET /v1/speakers/{slug}` and `GET /v1/speakers/{year}/{slug}`
* `GET /v1/sponsors` and `GET /v1/sponsors?year=2025`
* `GET /v1/sponsors/{slug}` and `GET /v1/sponsors/{year}/{slug}`

`language` is `Perl`. `framework` is `HTTP::Daemon`. `language_version` is the running process's `$^V` (`sprintf("%vd", $^V)`). `api_version` is `0.2.0`. `schema_version` is `1`. `created_year` is `2026`.

`photo_path` and `logo_path` are returned as stored web paths. This process does not serve the image bytes. The CMS usually hosts them.

## Register on boot (once)

`main` binds `HTTP::Daemon`, then `spawn_registration` forks. The child closes the inherited listener, calls `register_with_elixir`, and `POSIX::_exit`s. The parent sets `$SIG{CHLD}` to `IGNORE` and enters `accept` immediately.

`POST {CAROLINA_URL}/internal/api-endpoints/register`

```
Authorization: Bearer {POLYGLOT_REGISTER_TOKEN}
Content-Type: application/json
```

Body fields: `language`, `language_version`, `api_version`, `framework`, `created_year`, `base_url` (`PUBLIC_BASE_URL`, or `http://127.0.0.1:$PORT` when that variable is unset), `schema_version` (1), `endpoints` (the same `{ method, path, query }` objects that `GET /` returns).

`HTTP::Tiny` uses a 5 second timeout. Registration does not open Postgres.

Do not heartbeat. Elixir keep-alives the currently warm API.

If `CAROLINA_URL` or `POLYGLOT_REGISTER_TOKEN` is empty, skip registration. If the POST fails (connection refused, timeout, 4xx, or 5xx), log a warning and keep serving.

## Listen

`listen_host` returns `::`. `HTTP::Daemon->new` sets `LocalAddr` to that host, `V6Only => 0`, `ReuseAddr => 1`, `Listen => 16`, and `GetAddrInfoFlags => 0`. Zero flags keep glibc from applying `AI_ADDRCONFIG`, which drops `::` on a host that has no global IPv6 address. With `V6Only` off, that socket is IPv6 dual-stack and also accepts IPv4.

`accept` forks one child per client and returns to the listen loop. The child performs `get_request`. A quiet HTTP/1.1 socket, or a socket that never sends a complete request, must not stay in the parent. The child read timeout is `CLIENT_READ_TIMEOUT` (2 seconds).

## Layout

| Path | Role |
| --- | --- |
| `app.pl` | Server, routes, SQL, and registration |
| `cpanfile` | Runtime version pins, plus test and develop phases |
| `Dockerfile` | `perl:5.40-slim` and the runtime modules. Develop tools stay out |
| `Makefile` | `make check`, `make hooks`, and the individual gates |
| `t/` | `prove` suite. `app.pl` runs `main` only when it is the executed program |
| `fly.toml` | Fly service, including `min_machines_running = 1` in `iad` |
| `MEMORY.md` | Living gotchas |
| `DECISIONS.md` | Append-only decisions |
| `.perlcriticrc`, `.perltidyrc` | Critic profile and tidy settings |

## Quality gates

`make check` runs `prove` (`make test`), Perl::Critic (`make sast`), `cpan-audit` (`make audit`), `perltidy --assert-tidy` (`make lint`), and `gitleaks` (`make secrets`). `make hooks` installs those five checks as local pre-commit hooks. `Perl::Critic`, `Perl::Tidy`, and `CPAN::Audit` are develop-only. Install them with `make deps`. They are absent from the production image.

The Perl::Critic profile in `.perlcriticrc` is an injection and command-execution gate. The stock `security` theme only covers two-arg `open` and a UTF-8 layer, so this repo does not rely on that theme alone.

## Checklist

* CMS OpenAPI paths return 200 with example-shaped JSON, and 404 for an unknown slug
* `?year=` speaker rows include `languages` and `topics`
* `?year=` sponsor rows include `tier` (and `blurb`)
* Register runs once, after the listener binds, and still serves if the Elixir site is down
* No writes, and no Ash table names in SQL
* `GET /health` stays `{"ok":true}` and stays off the database
* `make check` passes

## Cursor Cloud

Start Postgres 16 for live HTTP. Point `DATABASE_URL` at the CMS database that already holds the `v1_*` views. Registration no-ops when the CMS on `CAROLINA_URL` is down. Use `PUBLIC_BASE_URL` and `PORT` as in the README.
