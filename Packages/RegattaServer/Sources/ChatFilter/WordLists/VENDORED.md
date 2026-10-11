<!-- machine-generated: for agents, not human readers -->
# Word lists

`<language>.txt` (en es fr ar zh ga) and `LICENSE` are vendored here, unchanged (fetched 2026-10-11), from
`coffee-and-fun/google-profanity-words` v3.0.7, commit `0ae3460` (MIT): the repo's `data/<language>.txt`.
One entry per line. `allow.txt` is ours: entries the lobby lets through.

`ChatWordList.bundled()` reads every `<language>.txt` here. Should a build ever lack them it throws `missing`: a
server outside `ENV=dev` then refuses to start; a dev server logs it and filters by `CHAT_EXTRA_BLOCKED_PHRASES` alone.
