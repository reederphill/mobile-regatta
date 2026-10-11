# The lobby is a hub in memory, written through to Postgres

The lobby's chat is one global room held by one in-process hub: who is reading, the last hour's lines, who blocks whom, who is racing and the posting limits live in memory, and every line and block is written to Postgres before anyone is told. Built in [#152](https://github.com/reederphill/mobile-regatta/issues/152).

## The decisions

- **One process, one room.** The hub is a lock-guarded table, not a broker: fan-out is a loop over at most 1024 feeds (512 service connections, two feeds a player). When the server becomes more than one process the hub needs a shared bus; nothing else in this design does.
- **Write-through, then fan-out.** A line is stored (2 s deadline), then appended to the in-memory hour and told to the feeds, one line at a time on one chain. So the store's id order is the delivery order, clients dedupe by id, and a restart rebuilds the hour and the block graph from the store. Lost on restart: the limits, the feeds, the classifier's breaker and the silence window (a crash cancels the races that silenced anyone).
- **A line carries its author as she was.** Nickname, rating, badge and chip are snapshotted into the row at post time. History never re-reads a player, and a rating change doesn't rewrite old lines. The cost: a nickname override (#153) or a deletion (#160) has to act on the stored lines, which `remove` and `deleteAll` do.
- **Not sent is never stored.** A post the filter blocks goes back to its sender alone. It is not stored, fanned out or logged; only counters record that it happened.
- **What fails closed.** A chat standing that can't be read (2 s): the post isn't sent. A line the store won't take: not sent. The history or the state unreadable: no answer, and the connection closes. A feed 64 events behind: cut, with no gap in what it got; the client reopens and reads the history.
- **What fails open: the classifier.** The bundled word list always applies. The toxicity classifier (OpenAI's moderation endpoint) is an extra check: a timeout (2.5 s), an error, more than 8 calls in flight or an open breaker (5 failures in a row, 30 s, one probe) lets the message through on the word list alone, and the pass is counted. Owner ruling, 2026-10-11: chat stays open when the filter service is down. The cost is that toxic text the word list doesn't know gets through during an outage; reports and moderation (#153) are the backstop.
- **The silence window is the hub's, told by the race.** The queue says when a fleet locks, a seat is given up and a race ends; the race lifecycle says when a seat has a result. Silence is keyed by race, so an old race's close can't open the lobby to a player locked into her next one, and it expires by itself 30 minutes after the lock.

## Considered and rejected

- **Postgres LISTEN/NOTIFY or a broker now.** One process serves every connection; a bus would add a failure mode and no reach.
- **Reading history from Postgres on each open.** One query per lobby open, against a table that keeps 30 days; the in-memory hour answers from a lock.
- **Failing closed on the classifier** (the brief's first answer): an outage of somebody else's service would silence free text for everyone.
- **Masking a blocked word.** The owner's rule (#17) is "not sent", shown only to the sender.
