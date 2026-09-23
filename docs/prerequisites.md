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
