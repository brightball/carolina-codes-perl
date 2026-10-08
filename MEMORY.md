# Memory

Short living notes for agents in this repository. Current instructions are in `AGENTS.md`. Settled choices and their reasons are in `DECISIONS.md`. Update a bullet here when the fact changes. Do not paste the decision log into this file.

## Runtime

- Project Perl is the image `perl:5.40-slim`. `LANGUAGE_VERSION` is `$^V` inside that process. A host `perl -v` of 5.42.x is a different interpreter.
- `cpanfile` pins `HTTP::Daemon` at 6.17 for `make deps`. The `Dockerfile` `cpanm` line names the runtime modules and does not pass those version numbers.
- `app.pl` defaults `PORT` to `4006`. The image and `fly.toml` set `PORT=8080`.
- `GET /health` encodes JSON true: `{"ok":true}`. It returns before any SQL.
- The listen socket is `::` with `V6Only => 0` and `GetAddrInfoFlags => 0`. Dropping the zero flags makes glibc `AI_ADDRCONFIG` hide `::` on hosts with no global IPv6 address, and the daemon fails to bind.
- `main` runs only when `app.pl` is the executed program (`main() unless caller`). Tests `require` the file and call the subs.
- `parse_db_url` defaults `sslmode` to `disable` unless the URL already sets it. The local dev URL user and password are `postgres` / `postgres`.
- One `$DBH` is reused while `ping` succeeds inside that process. `$CONNECT_FN` and `$QUERY_FN`, when set, replace the real connect and query path.
- The accept loop forks one child per client and closes the client socket in the parent. `get_request` blocks, and HTTP/1.1 leaves the socket open, so that wait has to stay in the child. The child read timeout is 2 seconds. The child sets `$DBH` to undef before it serves, then opens its own handle.

## Data

- Views the process selects: `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_sponsors`.
- Year speaker rows are `v1_speakers` filtered through `v1_talks`.
- A `?year=` speaker list is three queries (speakers, talks for the year, years for that slug set), then tags are attached in process. It is not one query per speaker.
- List bodies are `{ "data": [ ... ] }`. Missing slugs and non-GET methods are `404` `{ "error": "not_found" }`.
- `photo_path` and `logo_path` are returned as stored. This process does not serve image files.
- Handler tests use the fake catalog. Live HTTP needs the CMS database on Postgres 16. There is no Compose Postgres in this repo.

## Registration and deploy shape

- Registration forks after bind. The child closes the listener and exits with `POSIX::_exit`. The parent ignores `SIGCHLD`.
- The register POST times out in 5 seconds and does not open DBI. A missing URL or token skips it. Failure is a warning.
- `endpoints` in the register body are `{ method, path, query }` objects, the same array `GET /` returns.
- `fly.toml` keeps one machine up in `iad` (`min_machines_running = 1`). Health checks `GET /health`.

## Gates and workspace

- `make check` is prove, Perl::Critic, cpan-audit, perltidy, and gitleaks. Develop modules live in the `cpanfile` `develop` phase and in `local/` after `make deps`. They are not in the production image.
- `.perlcriticrc` is `only = 1` with an injection and command-execution set. Passing the stock `security` theme is not the gate.
- Gitea workflow steps run under dash: `set -eu`. `set -o pipefail` fails there.
- `local/` is gitignored cpanm output. `app.pl.bak` and `t/handler.t.bak` are leftover backups; leave them unless asked.
- This directory is the workspace root. The CMS OpenAPI file is in the other repository. Do not add a local `openapi.yaml` to mirror it.
- Keep private hosts, Fly auth, and real tokens out of these Markdown files. The public local examples (`postgres` / `postgres`, register token `dev`) are the ones already in the README.
