# Mobile monetization norms for niche competitive games

Research for [ticket 05](../wayfinder/tickets/05-mobile-monetization-norms.md). All sources accessed **2026-09-22** unless noted. Figures quoted from third-party data (RevenueCat, Adweek, PocketGamer.biz) are those companies' numbers, not Apple's.

## TL;DR

- **The closest analogue to Regatta is chess.com, not a mainstream F2P shooter.** Chess.com makes all play free and sells improvement tools (game review, insights, advanced stats) plus ad removal. It has about 2M payers out of about 250M registered users (about 0.6%), and subscriptions are about 88% of roughly $150M revenue. Regattatron uses the same model: "Free to race. Pro to find out why you lost."
- **Subscriptions are allowed for games under Apple's rules.** They must deliver ongoing value, run at least 7 days, work on all the user's devices, and say clearly what the user gets before purchase (3.1.2).
- **Loot boxes are allowed but must disclose odds before purchase (3.1.1)** and are an age-rating input. Nothing in the guidelines stops a game selling direct cosmetics.
- **Apple's cut is 15% for us.** We would pay 15% under the Small Business Program (under $1M proceeds a year), and 15% on subscription renewals after a subscriber's first paid year even at the standard 30% rate. On the **US storefront only**, apps may now link out to web purchase. That currently carries zero Apple commission, but the case is being litigated at the Supreme Court (merits brief filed 2026-09-14).
- **Buying anything on the web** is fine if it is **also** sold as IAP in the app (3.1.3(b)).
- **Best non-pay-to-win fit:** free racing for everyone, plus an optional **Pro subscription for debrief and analytics** (roughly $4.99/mo or $29.99–39.99/yr), plus **direct-purchase cosmetic liveries**. Skip loot boxes, skip pay-for-power passes, and use no ads during races.

## 1. Models in niche, skill-based, real-time multiplayer games

| Model | Example (price) | What's sold | Pay-to-win risk | Evidence |
|---|---|---|---|---|
| **Free play + "improvement" subscription** | Chess.com Gold / Platinum / Diamond. Diamond is $119/yr and over half of payers. Annual plans are about 40% off monthly. | Game review, coach explanations, insights, advanced stats, lessons, no ads. All play, tournaments and leaderboards are free. | None. Paid features teach; they don't act in-game. | ~2M paying subscribers of 250M registered (~0.6%). ~$150M revenue, ~88% subscriptions, ~10% ads ([Adweek, early 2026](https://www.adweek.com/media/chess-makes-new-advertising-gambit/)). Tier features: [Chess.com Help Center, updated 2022-09-01](https://support.chess.com/en/articles/8562418-what-does-each-level-of-premium-membership-get-me). |
| **Free play + analytics/cosmetic sub (web)** | Regattatron Pro: $5/mo or $40/yr ("four months free") | Post-race debrief (start performance, favoured tack, position ladders), high-res textures, custom sail graphics. All races and basic liveries free. | None by design ("Every race is free, forever"). | [regattatron.com](https://regattatron.com). No public conversion data. |
| **Pay-for-performance consumables** (the sailing incumbent) | Virtual Regatta Offshore: credits buy boat "options" (sails, VMG and routing aids). VIP subscription. | Performance aids | **High.** It is the textbook sailing pay-to-win case. | 1.5M active players (2020), >1M unique users for the 2020–21 Vendée Globe ([Wikipedia](https://en.wikipedia.org/wiki/Virtual_Regatta)). Player petition "Make Virtual Regatta Fair. No Pay-to-win" ([change.org](https://www.change.org/p/virtual-regatta-make-virtual-regatta-fair-no-pay-to-win)). VR's own help centre (virtualregatta.zendesk.com) returned 403 and could not be checked. |
| **Battle / season pass** | Brawl Stars Brawl Pass $8.99, Pass Plus $12.99 from 2026 ([Sportskeeda](https://www.sportskeeda.com/mobile-games/brawl-stars-brawl-pass-rework-new-prices-features); regional prices vary). Marvel Snap Premium $9.99, Premium+ $14.99 ([Dot Esports](https://dotesports.com/marvel/news/is-the-marvel-snap-premium-season-pass-worth-it)). | Progression tracks mixing cosmetics and power (new cards, brawler progression). | Medium to high when passes carry power. Cosmetic-only passes are fine. | Supercell 2025: €2.65bn ($3bn) revenue (−4%), EBITDA €932M (+6%), 290M MAU. Brawl Stars store sales est. −57% ([PocketGamer.biz, 2026-02-10](https://www.pocketgamer.biz/supercell-revenue-declines-4-to-265bn-in-2025/)). Mass-market, so not a niche benchmark. |
| **Free + one-off content unlocks** | The Battle of Polytopia: free, tribes $0.99–$1.99 as IAP. Online multiplayer matchmaking. | Extra playable factions, bought directly | Low if the unlocks are sidegrades | [App Store listing](https://apps.apple.com/us/app/the-battle-of-polytopia/id1006393168) |
| **Premium (paid up front)** | Common for niche sims, but it creates a player-count problem for real-time matchmaking. | The whole game | None | No reliable public conversion data found. |
| **Ads** | Rewarded video or interstitials | — | None directly, but they hurt the experience in competitive play | Mobile games made >$12B in ad revenue in 2025. Ads are 55–70% of revenue in growth markets, but **IAP is 77–90% in US/CA/KR/JP** ([Sensor Tower via GameDev Reports](https://gamedevreports.substack.com/p/sensor-tower-mobile-game-ad-monetization)). |

### Subscription benchmarks for games ([RevenueCat State of Subscription Apps 2026 – Gaming](https://www.revenuecat.com/state-of-subscription-apps-2026-gaming))

The sample is 115k+ apps, $16B revenue, mostly 2025 data. These benchmarks are skewed toward casual and utility "games" with weekly plans, so read them as a floor for a niche enthusiast audience, not a forecast.

- **Download-to-paid (day 35):** median **1.0%**, top quartile 2.3%. This is the lowest of any category.
- **Trial-to-paid:** median 25.0%, top quartile 39.8%. Across all categories, 17–32-day trials convert at **42.5%** versus 25.5% for trials of 4 days or less ([overview](https://www.revenuecat.com/state-of-subscription-apps)).
- **Median prices:** weekly $5.81, **monthly $4.99, annual $24.99**. Only 13% of game subscriptions sold are annual.
- **Realised LTV:** $8.41 at month 1, $11.22 at year 1. Revenue per install at day 60 is $0.14.
- **Mix:** gaming leads hybrid monetization at about 4× the average. 27.5% of games pair subscriptions with consumables.
- **Paywall type:** across all categories, hard paywalls convert 10.7% versus 2.1% for freemium by day 35, but one-year retention is nearly identical.

Chess.com's ~0.6% payer ratio is against *registered* users, which includes a large inactive base, so conversion among active users is higher. For a niche sailing audience, 1–5% of active players converting to a debrief subscription is a plausible planning range. That is an inference, not a sourced figure.

## 2. App Store Review Guidelines constraints

Source: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/). Latest revisions: 2026-02-06 (random/anonymous chat falls under 1.2 UGC, per [news](https://developer.apple.com/news/?id=d75yllv4)) and June 2026 (In-App Purchase API clarifications).

### Must use IAP (3.1.1)
- Unlocking features or content, including subscriptions, game currencies and premium content, must go through IAP. License keys, QR codes and similar mechanisms are not allowed.
- Purchased currencies **may not expire**, and there must be a restore mechanism.
- **Loot boxes:** "Apps offering 'loot boxes' or other mechanisms that provide randomized virtual items for purchase must disclose the odds of receiving each type of item to customers prior to purchase."
- Gifting IAP items is allowed.
- **Cosmetics** have no special rule. They are ordinary IAP (non-consumable or consumable).

### Subscriptions (3.1.2)
- Allowed "regardless of category". Must "provide ongoing value". The period must be **at least 7 days**. Must be **available across all of the user's devices** (iPhone and iPad for us).
- "Multiplayer support" and "consistent, substantive updates" are named as appropriate uses.
- Subscriptions can sit alongside à la carte IAP. A subscription may include currency or discounted items.
- The paywall must "clearly describe what the user will get for the price" (3.1.2(c)). Users must not be able to buy two variants of the same subscription by accident (3.1.2(b)); Apple recommends a single subscription group ([Apple subscriptions page](https://developer.apple.com/app-store/subscriptions/)).
- **Migration rule:** if the business model later changes, "you should not take away the primary functionality existing users have already paid for."

### Cross-platform and web purchases (3.1.3)
- **3.1.3(b) Multiplatform services:** content or subscriptions bought on other platforms or the web can be used in the iOS app, "provided those items are also available as in-app purchases within the app."
- **US storefront:** since the [2025-05-01 update](https://developer.apple.com/news/?id=9txfddzf) (after the Epic v. Apple injunction), US apps may include buttons and links to web purchase with no entitlement needed. Everywhere else, the in-app steering ban remains, apart from the entitlement programmes.
- **Commission on link-outs is unsettled.** In Dec 2025 the Ninth Circuit let Apple seek a "reasonable" cost-based fee. As of 2026-04-29 the commission is zero pending further proceedings, and Apple filed its Supreme Court merits brief on 2026-09-14 ([Tech Times, 2026-09-15](https://www.techtimes.com/articles/327527/20260915/app-store-commission-limbo-enters-new-phase-apples-epic-merits-brief-opens-scotus-fight.htm); [Courthouse News](https://www.courthousenews.com/apples-fight-over-commissions-for-linked-out-app-store-purchases-continues-in-federal-court/)). Don't build the business case on free link-outs.

### Other relevant rules
- **5.3.3:** IAP can't be used for real-money gaming. **5.3.1–5.3.2:** contests must be sponsored by the developer, with official rules in the app that disclaim Apple. This matters if we ever run prize regattas.
- **3.2.2(x):** apps may incentivise actions such as watching an ad or completing a level, but may not force ratings or reviews.
- **2.5.18:** ads must suit the age rating and have visible close buttons, and users must be able to report ads.
- **Age ratings** ([App Store Connect reference](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/); new questions added [2025-07-24](https://developer.apple.com/news/?id=ks775ehf)): loot boxes push the rating to at least **9+**. "Contests" (skill-based competition) are 4+ if infrequent and **13+ if frequent**. Messaging/chat and UGC are declared from 4+. Lobby chat and ranked racing are rating inputs.

### Commission tiers
| Situation | Apple's commission |
|---|---|
| Standard IAP or paid app | 30% |
| **Small Business Program** (developer and associated accounts earned ≤ $1M proceeds in the prior calendar year, or are new; must enrol) | **15%** on paid apps and IAP. Crossing $1M mid-year moves future sales to the standard rate. Falling below it lets you requalify the following year. ([Apple](https://developer.apple.com/app-store/small-business-program/)) |
| Auto-renewable subscription after the subscriber has **1 year of paid service** in the group | 15% (developer gets 85%). Free trials don't count toward the year. A lapse of up to 60 days pauses the count rather than resetting it. ([Apple](https://developer.apple.com/app-store/subscriptions/)) |
| EU alternative terms: Small Business Program or subscriptions after year one | 10% ([Apple](https://developer.apple.com/app-store/small-business-program/)) |
| US link-out web purchase | Currently $0 to Apple, under litigation (see above). Card processing fees still apply. |

## 3. Regattatron compared

| | Regattatron | Chess.com | Virtual Regatta | Norms from the benchmarks |
|---|---|---|---|---|
| Racing or play | Free, all modes | Free, unlimited | Free, but performance options cost credits | — |
| Paid core | Pro debrief and analytics | Game review, insights, stats | Performance options, VIP | — |
| Monthly | $5 | about $5–17 by tier (third-party figures) | credits, roughly £11/week reported by users | median $4.99 |
| Annual | $40 (33% off) | Diamond $119 (~40% off) | — | median $24.99 |
| Cosmetics | Basic liveries free; Pro adds high-res and custom sails | — | — | — |
| Pay-to-win | No | No | Yes | — |

Regattatron sits at the games median monthly price and well above the games median annual price. That is reasonable for an enthusiast niche, where chess.com shows buyers pay more for "why did I lose" tools. It is web-based, so as an iOS app **it would owe Apple 15–30% on any IAP** and must offer Pro as IAP if Pro is sold on the web (3.1.3(b)). Its "Pro includes cosmetics" bundling is allowed (3.1.2(a) permits subscriptions alongside à la carte items).

Two points to watch if Regatta copies it:
1. Apple requires a subscription to provide **ongoing value**. A debrief after every race qualifies more clearly than a one-time cosmetic unlock.
2. Regatta's v1.0 scope excludes AI coaching and written debriefs, and has no replays. So any Pro debrief must come from recorded race data (charts, ladders, start stats). That is the same kind of content Regattatron sells.

## 4. Options that fit a game that must never be pay-to-win

Ranked by fit:

1. **Free racing plus a Pro subscription for debrief and stats.** This follows the chess.com and Regattatron model. Suggested prices: $4.99/mo and $29.99–39.99/yr in one subscription group, with a 1–4 week free trial (longer trials convert better). The Small Business Program keeps the commission at 15%. Ranked queues, ratings and every racing feature stay free. **Constraint:** keep in-race information identical for free and Pro players (no wind overlays, laylines or routing aids for Pro), or the model turns into Virtual Regatta's.
2. **Direct-purchase cosmetic liveries (non-consumable IAP)** alongside Pro. Some can be Pro-exclusive or discounted for Pro, which 3.1.2(a) allows. Show exact items, not randomised packs, so there are no odds-disclosure or loot-box age-rating implications.
3. **A cosmetic-only season track,** optional and later. It fits ranked seasons (still unspecified on the map). It must hold no boat performance, and it is best folded into Pro to avoid a second paid product. Worth deferring: season passes suit high-DAU games, and the niche benchmarks are thin.
4. **A premium up-front price** gives no pay-to-win risk, but it shrinks the real-time player pool that matchmaking needs. Not recommended for v1.0.
5. **Avoid:** loot boxes (odds disclosure, 9+ rating and reputational risk), buying performance consumables (the Virtual Regatta pattern), and ads during races. At most, consider rewarded ads for cosmetic currency outside races. Ads earn little in US/UK/AU-weighted markets where IAP is 77–90% of revenue.

**Forward constraints for 1.1 and 1.2 (noted, not designed):** a regatta series or career ladder could be a Pro perk only as stats or cosmetics, never as entry gating that splits the matchmaking pool. Keep a single subscription group so a future "Pro+" is an upgrade within the group (3.1.2(b)). If prize regattas ever happen, 5.3.1–5.3.2 apply.

## Gaps
- No public conversion data for Regattatron, Virtual Regatta or any niche sailing title.
- Chess.com's per-tier monthly prices come from third-party blogs; the official membership page doesn't render prices when fetched.
- Virtual Regatta's own help-centre pricing pages returned HTTP 403.
