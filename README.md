# Territorio

A tile-locked expansion mod for Factorio. You start confined to four chunks and buy the
rest of the map with tokens earned from research.

**Mod portal:** https://mods.factorio.com/mod/territorio

## What it is

The map generates completely normally, with whatever preset you like. You just cannot walk
on most of it. You spawn boxed into a 2x2 block of chunks with 10 expansion tokens, and
every Territorial Expansion technology you research grants more. You spend them from the
map view on chunks adjacent to what you already own.

The result is a factory built under a constraint vanilla never applies: area. Science per
minute is capped by how much map you were willing to buy.

Bots and biters deliberately ignore the border. Bots fly over locked chunks, so ring-shaped
territory is a real strategy; biters walk through them, so turret-creeping outward is not.

Full feature list and the balance notes are on the mod portal page, and in
[`changelog.txt`](changelog.txt).

## Installing

Grab the zip from the mod portal, or drop this repository's contents into a folder named
`territorio` inside your Factorio `mods/` directory.

Requires **Factorio 2.1**. The base game is fully supported; Space Age is optional. The mod
was tuned against Space Age on Nauvis, and the other planets are not tested.

## Status

Version 0.9.0. Feature-complete and played end to end on Nauvis, but a work in progress.
Bug reports and balance feedback go in the **Discussion** tab on the mod portal page.

## Repository layout

This repository mirrors exactly what ships in the mod zip, nothing else. It is generated
from a separate development tree, so it has no development history, no design notes, and
no build tooling.

    info.json      mod manifest
    data.lua       data phase entry point
    control.lua    control phase entry point, the only place events are registered
    settings.lua   the one startup setting (Territory limit)
    prototypes/    technologies, items, shortcuts, the Mortar and Missile Battery
    scripts/       runtime logic, one module per system
    locale/        English strings

The comments in `scripts/` are the mod's real documentation. They record engine behaviour
that took probing to establish rather than restating what the code does.

## License

MIT. See [LICENSE](LICENSE).
