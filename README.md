# Tidebound

A cozy fishing RPG on Roblox — Stardew Valley × Pokémon. Explore a living archipelago, catch 200+ unique fish, build and decorate personal aquariums, and compete in seasonal tournaments.

**Team:** Empire Forge  
**Status:** MVP Development

## Tech Stack

- **Framework:** [Knit](https://github.com/Sleitnick/Knit) — service-oriented architecture
- **Build:** [Rojo](https://rojo.space/) — filesystem-to-Roblox sync
- **Language:** Luau (typed)
- **Dependencies:** Wally

## Project Structure

```
tidebound/
├── default.project.json    # Rojo project config
├── wally.toml              # Wally dependencies
├── src/
│   ├── server/             # Server scripts → ServerScriptService
│   │   └── ...
│   ├── client/             # Client scripts → StarterPlayer/StarterPlayerScripts
│   │   └── controllers/    # Client-side controllers
│   ├── shared/             # Shared modules → ReplicatedStorage/shared
│   │   ├── Types.luau      # Core type definitions
│   │   ├── FishCatalog.luau # All 60 MVP fish catalog entries
│   │   └── ProgressionMath.luau # XP curves, rod stats, weight classes
│   └── assets/             # Models, sounds, textures → ReplicatedStorage/assets
```

## Setup

### Prerequisites

- [Rojo](https://rojo.space/docs/v7/installation/)
- [Wally](https://wally.run/install)
- Roblox Studio

### Install

```bash
# Clone the repo
git clone https://github.com/dstroppa/tidebound.git
cd tidebound

# Install dependencies
wally install

# Build and sync to Roblox Studio
rojo serve
```

Then open a Roblox place and connect Rojo to sync the project.

## Development

- Server-authoritative architecture — all game logic (catch resolution, rarity rolls, economy) runs on the server
- Client is a "dumb renderer" — handles input and display only
- See `src/shared/Types.luau` for the full type system
- See the Game Design Document (GDD) for complete game specifications

## Branches

- `main` — stable, team lead-reviewed
- Feature branches — create PRs for review

## License

Proprietary — Empire Forge
