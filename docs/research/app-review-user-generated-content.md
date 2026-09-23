# App Review requirements for user-generated content

Research for [issue #33](https://github.com/reederphill/mobile-regatta/issues/33). All sources accessed **2026-09-23**. The App Review Guidelines quoted are the version marked "Last Updated: June 8, 2026".

Each finding is labelled with how sure I am of it:
- **High:** Apple's own published text says it.
- **Medium:** it's inferred from Apple's text, or App Review has said it repeatedly in rejections that developers quoted.
- **Low:** a single report, or my own reading.

## TL;DR

- **Guideline 1.2 itself lists only four things:** a filter, reporting with "timely responses", blocking, and published contact information. It says nothing about a EULA, "zero tolerance" or 24 hours. **(High)**
- **Reviewers ask for more.** App Review's standard 1.2 rejection message lists five precautions. Two of them aren't in the guideline:
  - "Require that users agree to terms (EULA)" that make clear there is "no tolerance for objectionable content or abusive users".
  - "act on objectionable content reports within **24 hours** by removing the content and ejecting the user".
  
  Developers have quoted this message word for word from 2018 to November 2025. Plan on meeting it. **(Medium–high)**
- **Apple's standard EULA isn't enough, but we don't need a custom EULA either.**
  - The standard EULA is a software licence that users accept with their Apple Account. It is never shown or accepted inside the app, and it has no rule against objectionable content.
  - A custom EULA would replace it and must carry Apple's ten minimum terms, including our postal address and phone number.
  - The simpler route: keep the standard EULA as the licence, and add a short in-app **Terms of Use** with a zero-tolerance clause, accepted with an explicit "I agree" tap before the player sees the lobby. **(Medium)**
- **Two gaps in what's already decided:**
  - The ~48 h review target should be **24 h**, and a reported message should be hidden at once.
  - GameKit says to turn off custom communication when `isUnderage` is true, not only when `isPersonalizedCommunicationRestricted` is true.
  
  Beyond 1.2, `isMultiplayerGamingRestricted` means online racing with strangers should also be off for those players. **(High for the API text; Medium for the 24 h)**
- **Filtering doesn't change the age rating.** In the current questionnaire, **Messaging and Chat** (which explicitly includes "public posting") is a capability allowed at **4+**, and there is no filtered or unfiltered option. What makes Regatta **13+** is **Frequent contests**, because every online race is competition for a rating. The one exception is Brazil, where chat alone gives **A12**. **(High for the table; Medium for how our features map onto it)**

## 1. What guideline 1.2 actually says

[App Review Guidelines §1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content): "apps with user-generated content or social networking services must include":

1. "A method for filtering objectionable material from being posted to the app"
2. "A mechanism to report offensive content and timely responses to concerns"
3. "The ability to block abusive users from the service"
4. "Published contact information so users can easily reach you"

The guideline also:

- Says apps used "primarily for pornographic content, Chatroulette-style experiences, random or anonymous chat, … making physical threats, or bullying do not belong on the App Store". The [2026-02-06 revision](https://developer.apple.com/news/?id=d75yllv4) added the "random or anonymous chat" wording. Our lobby is a single public room where every poster is shown by Game Center nickname and rating, not random pairing, so this is a low risk as long as moderation works. **(Medium)**
- Says "It is your responsibility to remove content that violates this guideline, **your terms of service, or your community standards**." That wording assumes the app has terms or community standards to enforce, but the guideline never says users must accept them. **(High for the text; the rest is inference)**
- Says that if Apple finds violating content, it will ask for a compliance plan and may remove the app until things improve.

Related guidelines:
- **1.5:** the app and its Support URL must include "an easy way to contact you".
- **2.1:** App Review needs the back end switched on and a way to reach every feature.
- **2.3.6:** answer the age-rating questions honestly.
- **5.1.1(i):** a privacy policy link in App Store Connect and in the app.
- **5.1.4:** apps that have "the ability to chat" with a minor "must include a privacy policy and must comply with all applicable children's privacy statutes".

**Not in the guideline text:** a EULA, affirmative acceptance of terms, "zero tolerance", or any response time in hours. **(High)**

## 2. What reviewers actually ask for

When App Review rejects an app under 1.2, it sends a standard message. Developers have quoted the same list word for word on Apple's forums. The earliest I found is from 2018 ([97052](https://developer.apple.com/forums/thread/97052)), then May 2019 ([116703](https://developer.apple.com/forums/thread/116703)), March 2019 ([115251](https://developer.apple.com/forums/thread/115251)) and **November 2025** ([807358](https://developer.apple.com/forums/thread/807358)):

> To resolve this issue, please revise your app to implement all of the following precautions:
> - Require that users agree to terms (EULA) and these terms must make it clear that there is no tolerance for objectionable content or abusive users
> - A method for filtering objectionable content
> - A mechanism for users to flag objectionable content
> - A mechanism for users to block abusive users
> - The developer must act on objectionable content reports within 24 hours by removing the content and ejecting the user who provided the offending content

A 2021 variant ([688227](https://developer.apple.com/forums/thread/688227)) lists only the items that app was missing. That suggests reviewers tick off the items one by one.

How sure I am of each point:

- **The five-item message is still in use in 2025.** **(Medium–high)** It appears verbatim years apart, most recently November 2025, but Apple doesn't publish it.
- **"Agree" means an affirmative action.** **(Medium)** One developer was rejected even though a sign-up line read "By signing up, you confirm that you agree to our Terms". The accepted fix was an "I Agree" button in front of the gated feature ([116703](https://developer.apple.com/forums/thread/116703)). Another was rejected even though users agreed at registration, and got through by adding an explicit accept step ([115251](https://developer.apple.com/forums/thread/115251)). These are community accounts; no Apple staff replied in either thread.
- **Recording acceptance:** a local flag or a server-side flag is what forum answers describe. Nothing official says how. **(Low)**
- **Other things reviewers have asked for:** **(Low; one thread, a social or events app, not a game)** The November 2025 second rejection ([807358](https://developer.apple.com/forums/thread/807358)) also asked for:
  - a way for users to remove their own posts immediately
  - contact information inside the app itself
  - an 18+ age rating
  - a demo account or demo mode

## 3. Apple's standard EULA or our own?

- **Standard EULA.** [Apple's Licensed Application EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) applies to every app that doesn't supply its own. [App Store Connect help](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/) says that when an app uses it, the product page shows no licence link. **(High)**
  - The standard EULA is a software licence covering scope, data, termination, no warranty and liability. Its only conduct clause says users won't use "External Services to harass, abuse, stalk, threaten or defame". It says nothing about objectionable content and no zero-tolerance rule. **(High)**
  - Users accept it through their Apple Account, not in the app. A forum regular, not Apple staff, put it this way: it "doesn't show when buying/installing/downloading apps" ([97052](https://developer.apple.com/forums/thread/97052)).
  - So on its own it doesn't satisfy "require that users agree to terms … no tolerance". **(Medium; inference from the EULA text and the rejection wording)**
- **Custom EULA.** It's entered as plain text in App Store Connect and **replaces** the standard EULA in the countries you choose. It must include Apple's [minimum terms](https://www.apple.com/legal/internet-services/itunes/dev/minterms/):
  - an acknowledgement that the agreement is with the developer, not Apple
  - licence scope
  - maintenance and support
  - warranty and refund via Apple
  - product claims
  - intellectual property
  - export compliance
  - **the developer's name, address, telephone number and email**
  - third-party terms
  - Apple as a third-party beneficiary
  
  **(High)** That is a lot of legal text, plus a published postal address and phone number, for no gain on 1.2. A custom EULA still wouldn't be accepted in the app unless we also show it there.
- **What comparable games do.** Supercell's Clash Royale and Brawl Stars show a "License Agreement" link, so they use a custom EULA, and link separate Terms of Service. Chess.com has no licence link, so it uses the standard EULA, and it has chat. Both approaches pass review. **(High for what the listings show)**

**Recommendation:** keep the standard EULA. Write our own short **Terms of Use** (community rules plus the zero-tolerance clause) and link it next to the privacy policy. Require an explicit **"I agree"** before the lobby is first shown. **(Medium)** This is exactly the question in #34.

## 4. What the current decisions already cover

Decisions from [#17 Lobby chat and moderation](https://github.com/reederphill/mobile-regatta/issues/17) and [#28 Telemetry, data retention and privacy](https://github.com/reederphill/mobile-regatta/issues/28), checked against the guideline and the reviewer message:

| Requirement | Source | Already decided | Gap or action |
|---|---|---|---|
| Filter | 1.2 text | Server filter: word list plus classifier; links and contact details stripped | None |
| Report | 1.2 text | Long-press Report | None. Consider letting players report a *player* (their nickname), not only a message. **(Low)** |
| Block | 1.2 text | Long-press Block, hides chat both ways, list in Settings | None |
| Published contact | 1.2 text, 1.5 | Support email in Settings and on the App Store page | None. It is inside the app, which a reviewer asked for in 807358. |
| Timely response | 1.2 text: "timely"; reviewer message: **24 h**, remove content, eject the user | Admin review within ~48 h; auto-mute after 3 reports; 24 h / 7 d / permanent ladder | **Gap.** Make the target **24 h**. Hide a reported message for the reporter at once and remove it on review. Say all of this in the review notes. The ladder counts as "ejecting". **(Medium)** |
| Terms with zero tolerance, affirmatively accepted | Reviewer message; 1.2 refers to "your terms of service" | Not decided | **Gap → #34.** Where to accept: before first opening the lobby is safest, because reading is also exposure to user content. Before the first free-text post is the minimum. **(Medium)** |
| Reviewer can reach every feature | 2.1 | Free text unlocks after one finished online race | **Gap.** A reviewer must be able to reach free text, report and block. Either make sure a lone reviewer can finish an online race (a fleet of bots at a quiet hour), or explain in the review notes how to reach it. Keep the back end up during review. **(Medium)** |
| Users can delete their own posts | One reviewer, 2025 (807358) | Not decided | Optional. A long-press **Delete** on your own message is cheap insurance. **(Low)** |
| Privacy policy, and children's privacy law if minors can chat | 5.1.1(i), 5.1.4 | Privacy policy linked in Settings | COPPA and GDPR-K compliance aren't covered by this research. See Gaps. |
| Account deletion | 5.1.1(v) | "Delete my online data" | None |

## 5. Game Center communication restrictions

- **`isPersonalizedCommunicationRestricted`** ([docs](https://developer.apple.com/documentation/gamekit/gklocalplayer/ispersonalizedcommunicationrestricted), iOS 14+): "If this property **or the underage property** is `true`, … If your game includes any custom communication features, you should disable them." The value comes from Screen Time settings, synced over iCloud. **(High)**
  - **Gap:** #17 checks only this property. The lobby should be hidden when **either** this property **or [`isUnderage`](https://developer.apple.com/documentation/gamekit/gklocalplayer/isunderage)** is true.
- **`isMultiplayerGamingRestricted`** ([docs](https://developer.apple.com/documentation/gamekit/gklocalplayer/ismultiplayergamingrestricted), iOS 13+): it is true when Screen Time multiplayer is set to "friends only" or "no one", and "If your game uses a custom multiplayer feature, you should disable it." **(High)**
  - This is outside 1.2, but it affects the queue: players with this restriction should get practice races only, since v1.0 has no friends-only online racing. Flag this for matchmaking and navigation.
- **Declared Age Range API** (iOS 26+, [docs](https://developer.apple.com/documentation/declaredagerange)): it returns a user's or parent's declared age range. It's the named mechanism in the age-rating options "Age Assurance" and "Social Media Disabled for Users Under 13". Regatta doesn't need it if the lobby isn't classed as social media (see §6). **(Medium)**

## 6. Age ratings and filtered chat

Source: [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/) and [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/).

**How the questionnaire treats chat and user content:**

- **Messaging and Chat** is defined as "Users can directly communicate with one another … May include: text … chat, direct and/or group messaging, **or public posting**." It is listed under **4+**. **(High)**
- **User-Generated Content** is defined as "broad distribution of content created by users … broadly distributed videos, photos, text". It is also **4+**. **(High)**
- **Social Media** is defined as "a social feed or similar discovery method that visibly spreads content to many users … views, likes, comments, and shares". It rates **13+** globally, **16+ in Australia**, **15+ in Korea** and **A16 in Brazil**.
  - The lobby has no feed, likes or shares, so **Messaging and Chat** is the right declaration, not Social Media. **(Medium)**
  - If we later add likes or reactions on lobby messages, this answer should be revisited.
- **Filtering changes nothing.** The questionnaire has no filtered or moderated option. Chat is declared as a capability either way. **(High)**

**Contests is what drives the rating:**

- "Contests" means "events that allow users to compete with one another for rankings". It is **4+** if infrequent and **13+ if frequent**. On devices before iOS 26, "Frequent or intense contests" gives **12+**. **(High)**
- Every online race moves a rating, so the honest answer (2.3.6) is **Frequent contests**, giving **13+**. That matches the 13+ expected in #28, but for a different reason. **(Medium)**
- Comparable listings, checked 2026-09-23. None of them declares Contests, so big competitive games answer this question narrowly. **(High for the listings; the interpretation is mine)**
  - Clash Royale: **9+**, "Messaging and Chat", with in-app controls for age assurance and parental controls.
  - Brawl Stars: **13+**, driven by frequent guns, plus "Messaging and Chat".
  - Chess.com: **4+**, "Messaging and Chat" and "Advertising".

**Other rating points:**

- **Brazil:** "Messaging and chat" rates **A12** (the global table allows it at 4+). Brazil's rating is shown automatically. **(High)**
- **Minimum age in a licence:** if the EULA sets a minimum age above the calculated rating, you "must override" to match. This would matter only if we used a custom EULA with an age floor. **(High)**
- **Game Center:** its presence changes nothing in the questionnaire.

## 7. Suggested inputs for #34 (terms of use)

1. **Keep Apple's standard EULA as the app licence.** No custom EULA.
2. **Write a short Terms of Use:**
   - Community rules
   - "No tolerance for objectionable content or abusive users", using the reviewer message's own wording
   - What gets removed, and the mute and ban ladder
   - The 24 h review commitment
   - How to report, and the support email
   
   Host it next to the privacy policy and link both in Settings → About.
3. **Explicit acceptance.** A full-screen sheet with the terms and an **I agree** button, shown the first time a player opens the lobby.
   - Declining means no lobby and no chat; racing still works.
   - Store the acceptance with a terms version on the server, against the Game Center player ID, and ask again when the terms change.
4. **Moderation service level:** move the target to 24 h and hide a reported message at once.
5. **Review notes:** explain the lobby, filter, report, block, the unlock rule and how a reviewer can reach free text.

## Gaps

- **The rejection message isn't published by Apple.** Everything in §2 comes from developers quoting it on Apple's forums. Apple could change it without notice.
- **Children's privacy law** (COPPA, GDPR-K, UK Age Appropriate Design Code) and **US state app-store age laws** (Texas, Utah, Louisiana) weren't researched. 5.1.4 makes the first group relevant, because chat is available to any signed-in player who isn't restricted.
- **Whether Game Center nicknames count as our user-generated content** to moderate. They are chosen in Apple's system UI and shown as-is. I found no Apple statement either way. **(Low)**
- **Whether quick-chat counts as user-generated content.** It is fixed text, so probably not, but it is still "messaging". Declaring Messaging and Chat covers it either way.
- **Whether a lone reviewer can finish an online race** depends on matchmaking behaviour that isn't decided yet.

## Sources

- Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (last updated 2026-06-08): §1.2, 1.5, 2.1, 2.3.6, 5.1.1, 5.1.4
- Apple Developer News, [Updated App Review Guidelines, 2026-02-06](https://developer.apple.com/news/?id=d75yllv4)
- Apple, [Licensed Application End User License Agreement (standard EULA)](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
- Apple, [Instructions for Minimum Terms of Developer's EULA](https://www.apple.com/legal/internet-services/itunes/dev/minterms/)
- App Store Connect Help, [Provide a custom license agreement](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/)
- App Store Connect Help, [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/) and [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
- Apple GameKit docs: [`isPersonalizedCommunicationRestricted`](https://developer.apple.com/documentation/gamekit/gklocalplayer/ispersonalizedcommunicationrestricted), [`isUnderage`](https://developer.apple.com/documentation/gamekit/gklocalplayer/isunderage), [`isMultiplayerGamingRestricted`](https://developer.apple.com/documentation/gamekit/gklocalplayer/ismultiplayergamingrestricted); [Declared Age Range](https://developer.apple.com/documentation/declaredagerange)
- Apple Developer Forums (developer-quoted rejection messages, community replies): [97052](https://developer.apple.com/forums/thread/97052) (2018), [115251](https://developer.apple.com/forums/thread/115251) (2019), [116703](https://developer.apple.com/forums/thread/116703) (2019), [688227](https://developer.apple.com/forums/thread/688227) (2021), [807358](https://developer.apple.com/forums/thread/807358) (2025)
- App Store listings (US): [Clash Royale](https://apps.apple.com/us/app/clash-royale/id1053012308), [Brawl Stars](https://apps.apple.com/us/app/brawl-stars/id1229016807), [Chess.com](https://apps.apple.com/us/app/chess-play-learn/id329218549)
