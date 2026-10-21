# Strategy Cycle Contract

> A form for passing facts from period closing to the decision package of the next strategic Session. **Source-of-truth:** [SPEC.md](SPEC.md).

## Why

Closing (a Session/day/week/month) and Opening are distinct moments — often distinct processes. This contract gives them a Ubiquitous Language that is not tied to whichever specific closing mechanisms are installed on a given installation.

## Status

`draft` — the form is defined and is already used as a reference from `memory/lpf-hypothesis-log.md` and the weekly Session steps, but the producer/consumer pair has not passed live acceptance on an installation without a dedicated server. Until acceptance, `roles/strategist/prompts/session-prep.md` remains the working implementation of the week Opening.

## If You Have No Producers

This is expected. The decision package from §4 SPEC degenerates to a single category (Work Products of the period) — the contract is designed so that this is a valid case, not an error.