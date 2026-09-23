# Prerequisites

Accounts, vendors and agreements set up by a person before the build tickets that need them. Each section is filled in by one `owner:human` ticket under [Human long-lead prerequisites](https://github.com/reederphill/mobile-regatta/issues/38).

## Chat filter

From [Chat filter vendor and word list](https://github.com/reederphill/mobile-regatta/issues/51). The [Lobby chat service](https://github.com/reederphill/mobile-regatta/issues/152) runs every free-text message through the word list and then the classifier ([#17](https://github.com/reederphill/mobile-regatta/issues/17)).

### Toxicity classifier

| | |
|---|---|
| Vendor | OpenAI moderation endpoint, model `omni-moderation-latest` |
| API docs | https://developers.openai.com/api/docs/guides/moderation |
| Endpoint | `POST https://api.openai.com/v1/moderations` |
| Cost | Free for OpenAI API users. It doesn't count towards usage limits. |
| Secret name | `OPENAI_MODERATION_API_KEY`, a key used only for moderation |
| Key location | The owner's password manager until the hosting secrets manager exists. [#50](https://github.com/reederphill/mobile-regatta/issues/50) moves it there. |
| Account | OpenAI API platform organisation, registered as an individual |
| Processor for the privacy policy | OpenAI OpCo, LLC |
| DPA | [OpenAI Data Processing Addendum](https://openai.com/policies/data-processing-addendum/) (effective 1 Jan 2026), signed through OpenAI's [Execute Data Processing Agreement](https://ironcladapp.com/public-launch/63ffefa2bed6885f4536d0fe) form, not in the platform UI. Signed September 2026 as an individual, with OpenAI OpCo, LLC. It covers the API on its own, so no ChatGPT Business seats are needed. |
| Sub-processors | https://platform.openai.com/subprocessors |
| Vendor retention | Up to 30 days for abuse monitoring. No training on API data. This fits the 30-day chat retention in [#28](https://github.com/reederphill/mobile-regatta/issues/28). |

Why this vendor: Perspective API shuts down after 31 Dec 2026, and self-hosting a model would mean running a Python sidecar next to the Swift server.

### Word list

| | |
|---|---|
| Source | https://github.com/coffee-and-fun/google-profanity-words, `data/*.txt` (en, es, fr, ar, zh, ga) |
| Pinned version | `v3.0.7`, commit `0ae3460863120bc671361b9403cc65d5f2075b89` |
| Licence | MIT. Keep its `LICENSE` next to the vendored copy. |

The server vendors the list at the pinned commit. Moving to a newer release is a deliberate change.

## Actions

From [Enable GitHub Actions and macOS runner minutes](https://github.com/reederphill/mobile-regatta/issues/48). Filled in after #48 closed without it.

| | |
|---|---|
| Enabled | 2026-09-23, on the private repo `reederphill/mobile-regatta` |
| Allowed actions | All (`gh api repos/reederphill/mobile-regatta/actions/permissions`) |
| Monthly macOS minutes budget | Not recorded. The account's included Actions minutes apply, and macOS minutes count 10×. |

## Hosting

From [Hosting account, server city and domain](https://github.com/reederphill/mobile-regatta/issues/50). Decided 2026-09-23.

| | |
|---|---|
| Provider | Hetzner Cloud. Account created 2026-09-23. |
| City | Ashburn, Virginia (`ash`). Every v1.0 race runs here ([#31](https://github.com/reederphill/mobile-regatta/issues/31)). |
| Reference instance type | The smallest shared-vCPU x86 plan in Ashburn, used by both production and the benchmark. The plan name and price are recorded here the first time one is created ([#69](https://github.com/reederphill/mobile-regatta/issues/69)). |
| CPU architecture | x86_64. It matches GitHub's x86 Linux CI, so the golden table ([#56](https://github.com/reederphill/mobile-regatta/issues/56)) needs no arm64 job. |
| Postgres | Self-hosted on its own small Hetzner server in Ashburn, so it never takes CPU from race ticks. Hetzner server backups are on, and a nightly `pg_dump` goes to R2. Staging runs Postgres on the staging server. |
| Object storage | Cloudflare R2 (free up to 10 GB) for `WindSeedPool` files and database dumps |
| Secrets manager | SOPS with age keys, encrypted in the repo. The age private key is kept in a GitHub Actions secret and on each server, never in git. Set up with the first server secret ([#167](https://github.com/reederphill/mobile-regatta/issues/167)); `OPENAI_MODERATION_API_KEY` moves in then. |
| Domain | `mobileregatta.com`, registered 2026-09-23 at Cloudflare Registrar, expires 2027-09-23 |
| DNS | Cloudflare (`tadeo.ns.cloudflare.com`, `tia.ns.cloudflare.com`). Game and API records are DNS only, not proxied. |
| TLS | Let's Encrypt certificates on each server |
| Load-test budget | Up to $50 a month on hourly Hetzner servers ([#168](https://github.com/reederphill/mobile-regatta/issues/168)) |

### When servers run

Nothing runs all the time before launch.

- **Production** (race server and Postgres) is created when the app is submitted to App Review, because reviewers need a live server. It stays up from then on.
- **Before that,** the benchmark ([#69](https://github.com/reederphill/mobile-regatta/issues/69), [#105](https://github.com/reederphill/mobile-regatta/issues/105)), staging ([#167](https://github.com/reederphill/mobile-regatta/issues/167)) and load tests ([#168](https://github.com/reederphill/mobile-regatta/issues/168)) run on servers created for one session and deleted afterwards. Hetzner bills by the hour.
- **Benchmark runner:** a self-hosted GitHub Actions runner labelled `regatta-ref`, registered on a reference-type server for each benchmark session and removed with it. The bench job is started by hand (`workflow_dispatch`), so no job waits for a runner that isn't there.
