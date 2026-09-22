---
id: 17
title: Netcode and authority model
labels: [wayfinder:grilling]
parent: map
status: open
assignee:
blocked_by: [3, 8, 12]
---

## Question

How does the client/server split work: server tick rate, what the client predicts (own boat? others?), input delay vs. prediction and reconciliation, interpolation of other boats, how contact and rule calls stay fair under latency, what happens on packet loss, and the latency budget beyond which a player is warned or excluded?
