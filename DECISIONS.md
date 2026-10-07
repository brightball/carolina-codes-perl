# Decisions

Append-only log of settled choices for this Perl 5.40 and `HTTP::Daemon` service.

Perl has no framework-native decision store (no Phoenix context, no Rails ADR generator, no PSGI plugin that records why). This file is that store. It is not a CPAN `Changes` release notes file. `AGENTS.md` holds the current working instructions. `MEMORY.md` holds short gotchas that are still true. Read both before changing behavior.

When you settle a choice, append a new entry at the bottom. Give it a date, a status, the decision, and why, including the alternatives the change replaced or that the tree considered. Leave an accepted entry's decision text in place. If a later entry replaces it, set the older status to `superseded by YYYY-MM-DD` and point at the new entry. Do not reopen a settled choice by editing its decision away.

Entries below are reconstructed from commits and from the code those commits left in the tree.

## 2026-08-28 — Single-file HTTP::Daemon service on Perl 5.40

- Status: accepted
- Decision: Ship one `app.pl`. The framework name reported to the CMS is `HTTP::Daemon`, pinned at 6.17 in `cpanfile`. The production image is `perl:5.40-slim`. `LANGUAGE_VERSION` is `sprintf("%vd", $^V)` of that process. Runtime modules are `HTTP::Message`, `HTTP::Tiny`, `DBI`, `DBD::Pg`, `JSON`, and `URI`. The image installs those names and then removes the compiler toolchain. Develop tools stay out of the image.
- Why: The public contract is a small read-only JSON API. The first commit (`883dae4`) implemented it as one process with `HTTP::Daemon` as the HTTP server and `DBI`/`DBD::Pg` for the views. A `src/` tree, a local OpenAPI file, and a Compose stack were never added.
- Alternatives: The language starter uses `src/`, a local `openapi.yaml`, and Compose. This repo kept the single script. A heavier Perl web stack (PSGI, Mojolicious, Dancer) is not in the tree.

## 2026-08-28 — CMS OpenAPI is the contract; query v1 views

- Status: accepted
- Decision: Do not vendor the HTTP contract in this repo. Routes and payloads follow the CMS files `priv/api/openapi.yaml` and `priv/api/AGENTS.md`. SQL reads `v1_*` views in the CMS database. Live HTTP uses that database on Postgres 16. The views `app.pl` queries are `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, and `v1_year_sponsors`. Year-scoped speakers are `v1_speakers` filtered by `v1_talks`, with `languages` and `topics` attached from those talks. Year-scoped sponsors, including `tier` and `blurb`, come from `v1_year_sponsors`. Leave Ash resource tables and base catalog tables out of queries.
- Why: The Phoenix CMS owns the schema and the public contract. A copied OpenAPI document or a local catalog would drift from the views the site actually serves. The speaker year filter is the `v1_talks` subquery already in `app.pl`.
- Alternatives: Shipping the starter's `db/*.sql` and a local `openapi.yaml`. Rejected by keeping the contract in the CMS remote.

## 2026-09-01 — Listen on IPv6 and keep health off the database

- Status: superseded by 2026-09-22 (dual-stack flags). The health rule is still accepted.
- Decision: `listen_host` is `::`, with `V6Only => 0`, so the socket is dual-stack. `GET /health` returns `{"ok":true}` and does not call `open_connection` or `db_query`. Catalog reads for a year of speakers are batched: one query for the speakers, one for that year's talks, one for the years of the slug set. One process-wide `$DBH` is reused when `ping` succeeds.
- Why: Commit `c07fce5` moved the listener off `0.0.0.0` so the process is reachable on Fly's IPv6 private network, kept the health check from depending on Postgres, and replaced per-row catalog queries with the batched reads. The original register call still ran before `accept`.
- Alternatives: The first commit listened on `0.0.0.0` only, which missed the IPv6 network. Per-speaker queries were the earlier catalog shape.

## 2026-09-06 — This git remote is the workspace root

- Status: accepted
- Decision: Agents treat `carolina-codes-perl` as the workspace root. They do not assume a sibling CMS checkout, and they do not move this tree into the CMS repository.
- Why: Commit `e20ac7d` added the Cursor Cloud environment so each polyglot remote can boot alone. The CMS database and OpenAPI contract stay in the other remote.
- Alternatives: A monorepo layout with `../elixir` always present. That checkout is optional and is often absent.

## 2026-09-22 — Registration stays off the accept path, and one Fly machine stays warm

- Status: accepted
- Decision: Bind the listener, then fork registration. The child closes the inherited daemon socket, `POST`s with `HTTP::Tiny` (5 second timeout), and `POSIX::_exit`s. The parent ignores `SIGCHLD` and accepts immediately. An empty `CAROLINA_URL` or `POLYGLOT_REGISTER_TOKEN` skips the fork. A failed POST is a warning. Registration does not open Postgres. `fly.toml` sets `min_machines_running = 1` in `iad` so an idle period does not stop the only machine.
- Why: Commit `1b7b424`. Register used to run in the parent before `listen`, so a CMS that accepted the TCP connection and never answered blocked `GET /health`. Fly's default idle stop cold-started the process. The prove suite covers the routes, bounded catalog SQL, connection reuse, and a CMS that never answers.
- Alternatives: Register-then-listen, which was the code from `883dae4` through `c07fce5`. A heartbeat, which the CMS contract does not ask for. Scale-to-zero, which the warm-machine setting replaces.

## 2026-09-22 — Quality gates are prove, critic, cpan-audit, perltidy, and gitleaks

- Status: accepted
- Decision: `make check` runs those five gates. `make hooks` installs the same five as pre-commit. `cpanfile` pins runtime modules and puts `Perl::Critic` 1.156, `Perl::Tidy` 20260826, and `CPAN::Audit` 20260622.001 on the develop phase. `.perlcriticrc` enables an injection and command-execution policy set at severity 1, `only = 1`. Gitea CI is one job per gate. Workflow shell is `set -eu` because the runner's `sh` is dash and rejects `set -o pipefail` (commit `05da37d`).
- Why: Commit `1b7b424` added the gates and recorded that Perl::Critic's named `security` theme covers only two-arg `open` and a UTF-8 layer. The dash fix keeps the workflow scripts executable on that runner.
- Alternatives: A single combined CI job. The stock critic `security` theme as the whole SAST gate. `pipefail` in the workflow scripts.

## 2026-09-22 — Dual-stack lookup must not use AI_ADDRCONFIG

- Status: accepted
- Supersedes: the listen flags in the 2026-09-01 entry. `::`, `V6Only => 0`, and health-off-database stay.
- Decision: `HTTP::Daemon->new` sets `GetAddrInfoFlags => 0` in addition to `LocalAddr => "::"` and `V6Only => 0`.
- Why: Commit `88cf51d`. glibc applies `AI_ADDRCONFIG` by default and hides `::` when the machine has no global IPv6 address. `HTTP::Daemon` then failed to bind inside the CI container. Asking for the named address, with `V6Only` left off, keeps the dual-stack socket.
- Alternatives: Leave the default addrinfo flags (bind failed in CI). Listen on `0.0.0.0` only (loses IPv6). Require a global IPv6 address on every build host.
