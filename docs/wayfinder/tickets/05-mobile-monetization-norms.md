---
id: 5
title: Mobile monetization norms for niche competitive games
labels: [wayfinder:research]
parent: map
status: closed
assignee:
blocked_by: []
---

## Question

What monetization models work for niche, skill-based, real-time multiplayer mobile games (subscription, premium, cosmetics, battle pass, ads), with example prices and conversion data where available? What App Store rules constrain them (subscriptions, loot boxes, cross-platform purchases)? How does Regattatron's free + $5/mo Pro debrief compare?

## Context

Findings: branch `research/mobile-monetization-norms`, file `docs/research/mobile-monetization-norms.md`.

## Resolution

Resolved by research; full findings on branch `research/mobile-monetization-norms` in `docs/research/mobile-monetization-norms.md`.

- **Best model to copy:** chess.com. All play is free, and paid tiers sell review, insights and stats. About 0.6% of registered users pay, and subscriptions are about 88% of revenue.
- **Benchmarks** (RevenueCat 2026, games):
  - Median prices: $4.99 a month, $24.99 a year.
  - About 1% of downloads convert to paid by day 35.
  - About 25% of trials convert.
- **Cautionary tales:**
  - Battle passes often include gameplay power.
  - Virtual Regatta's paid performance options are the sailing pay-to-win example.
  - In-app ads earn little in US and similar markets, where in-app purchases are 77–90% of game revenue.
- **Apple's rules:**
  - Subscriptions (3.1.2) must give ongoing value, last at least 7 days and work on all the user's devices.
  - Loot boxes must show odds and raise the age rating to at least 9+.
  - Web purchases (3.1.3(b)) are allowed only if the same item is also sold in the app.
  - Commission is 15% under the Small Business Program (up to $1M a year) and 15% on subscription renewals after the first year; 30% otherwise.
- **Regattatron** ($5/mo, $40/yr): the monthly price matches the game median; the annual price is high but plausible for an enthusiast audience.
- **Fit for a game that must never be pay-to-win:**
  1. Free racing, plus a Pro subscription for debrief and stats. Free and Pro players must see exactly the same information during a race.
  2. Cosmetic liveries sold directly, never as random packs.
  3. Possibly later, a cosmetic-only season track.

Gap: no public conversion data for Regattatron or Virtual Regatta.
