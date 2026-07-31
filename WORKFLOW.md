# Tidebound — Team Workflow

## Branch Strategy
- `main` — stable, production-ready code. Never commit directly.
- Feature branches: `feature/<short-description>` (e.g., `feature/catch-minigame`, `feature/coral-shallows`)
- Branch from `main`, open a PR to merge back.

## PR Process
1. Create feature branch from `main`
2. Implement the feature
3. Open a PR against `main` with a clear title and description
4. Lead reviews and merges

## Code Conventions
- Luau throughout (typed where possible)
- Server-authoritative for all game logic (catch resolution, economy, progression)
- Client is a dumb renderer — never trusts client input for outcomes
- Use Knit services for all server-side logic
- Follow the GDD at `/home/team/shared/tidebound-gdd.md` as the source of truth

## Commit Style
- `feat: <description>` — new feature
- `fix: <description>` — bug fix
- `chore: <description>` — tooling, config, non-code changes
