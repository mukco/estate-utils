# Adopting estate-utils

Nothing here has been done to any app. This is the list of what adoption costs,
written from the actual call sites rather than from memory.

## What moved, and what it is called now

| Was | Is |
| --- | --- |
| `Warehouse::Cached` | `Cache::Answers` |
| `Warehouse::Cached::BY_TTL` | `Cache::Answers::BY_TTL` — and the default, so mostly deleted |
| `Warehouse::AnswerLog` | `Cache::AnswerLog` |
| `Api::ServesCachedAnswers` | `Cache::ServesAnswers` |
| — (new) | `Cache::Warehouse`, the build-stamped variant |

The rename is the point, not incidental. `Warehouse::Cached` caches thirteen
things in baseball and exactly one of them is warehouse data — the rest are
model completions, and the module's own default argument (`stamp:
Warehouse::Manager.build_stamp`) was overridden by every single caller. The
name was describing a shape nobody used.

## The two injection points, and why they had to go

**1. `write` defaulted to the warehouse build stamp.** That is what dragged
`Warehouse::Manager` into a gem that has no warehouse. It could go because
nothing depended on it: `resolve` and `resolve_detailed` already defaulted to
`BY_TTL`; every one of the thirteen `read` call sites passes `stamp:
Warehouse::Cached::BY_TTL` explicitly; and `write`, `keep` and `current?` have
no callers outside the module itself in either app. `BY_TTL` is the default
throughout now, which is a **no-op for both apps** — verified by reading every
call site, not by inference.

The two services that genuinely track the warehouse —
`ottoneu_depth_movers_service.rb:22` and `prospect_insights_service.rb:40` —
pass `Warehouse::Manager.build_stamp` as a **fingerprint**, with `stamp:
BY_TTL`. That is a different argument and it keeps working unchanged; they may
just drop the now-redundant `stamp:` line. If either is ever meant to key on the
build rather than re-lease against it, `Cache::Warehouse` is what it wants.

**2. `ServesCachedAnswers` named `RefreshCachedInsightJob` directly.** It is
now `Cache.refresh_job`, set once in an initializer. Unset, it warns on every
call rather than raising (a request that could still serve the last good answer
must not 500) and rather than going quiet (an app whose answers silently never
refresh is the failure that hides for weeks).

## Baseball

**Gemfile**, next to the existing `estate-monitor` line:

```ruby
gem "estate-utils", git: "https://github.com/mukco/estate-utils.git", branch: "main"
```

**`config/initializers/cache.rb`** (new):

```ruby
Cache.refresh_job = RefreshCachedInsightJob
# Only if something adopts the stamped path; nothing does today.
# Cache::Warehouse.stamp_provider = -> { Warehouse::Manager.build_stamp }
```

**Delete** (all four now live in the gem):

- `app/services/warehouse/cached.rb`
- `app/services/warehouse/answer_log.rb`
- `app/controllers/concerns/api/serves_cached_answers.rb`
- `spec/services/warehouse/cached_spec.rb`, `spec/services/warehouse/answer_log_spec.rb`

**Rename** `Warehouse::Cached` → `Cache::Answers` in 13 services and 1 job:

```
app/services/daily_summary_service.rb          app/services/ottoneu_insights_service.rb
app/services/game_insights_service.rb          app/services/ottoneu_league_overview_service.rb
app/services/picks_service.rb                  app/services/ottoneu_lineup_insights_service.rb
app/services/prospect_insights_service.rb      app/services/ottoneu_player_analysis_service.rb
app/services/team_factoids_service.rb          app/services/ottoneu_team_overview_service.rb
app/services/ottoneu_auctions_waivers_service.rb
app/services/ottoneu_depth_movers_service.rb
app/services/ottoneu_free_agents_service.rb
app/jobs/warm_live_games_job.rb
```

plus `spec/services/game_insights_live_fingerprint_spec.rb` and
`spec/jobs/warm_live_games_job_spec.rb`.

In the same pass, every `stamp: Warehouse::Cached::BY_TTL` can be deleted — it
is the default. That is 13 `read` call sites and 9 `resolve` ones.

**`Warehouse::AnswerLog` → `Cache::AnswerLog`** in
`app/controllers/api/cache_warming_controller.rb` (the only user).

**`include Api::ServesCachedAnswers` → `include Cache::ServesAnswers`** in five
controllers: `teams`, `prospects`, `ottoneu`, `daily_summary`, `games`. The
`serve_cached` signature is unchanged, so no call site moves. Baseball's
hardcoded live-kind test (`game_insights:`, `picks:`) is the gem's default, so
the behaviour is identical; a new live kind is now added to
`Cache::ServesAnswers::LIVE_KINDS` or passed as `live:` at the call site.

The prose comments in eight service files that say "See Api::ServesCachedAnswers"
need the new name, or they become a dangling reference.

## Football

The same, smaller. Football has no `cache_warming_controller`, so `AnswerLog`
has no callers outside the gem at all.

- Gemfile line, initializer: identical to baseball's.
- Delete: `app/services/warehouse/cached.rb`, `app/services/warehouse/answer_log.rb`,
  `app/controllers/concerns/api/serves_cached_answers.rb`.
- Rename `Warehouse::Cached` → `Cache::Answers` in four services:
  `factoid_service.rb`, `daily_summary_service.rb`, `picks_service.rb`,
  `game_insights_service.rb`.
- `include Cache::ServesAnswers` in two controllers: `games`, `daily_summary`.

Football has no specs for either module today, so there are none to delete —
the gem's carried-over ones are the first coverage this code has had in that
repo.

## family-hub

**family-hub has none of this.** It has no `Warehouse::Cached`, no
`AnswerLog`, no `ServesCachedAnswers` — its slices cache by hand (see
`Reader::Definer` / `reader_lookups`). So it is not a migration; it is a
possible future adoption, and the gem is where it would come from rather than a
third copy of the file. The brief called this a three-app change; on the
evidence it is a two-app change with a third app as the reason for extracting
at all.

## What the rename touches at runtime

**Answer cache keys do not change.** `versioned_key` is still
`"#{name}:v#{stamp}"` and the last-good key is still `"#{name}:last_good"`, so
every cached answer survives the deploy. No page goes cold.

**One key does change**: `AnswerLog::KEY` moves from `"warehouse:answer_log"`
to `"cache:answer_log"`. The old log is orphaned and expires on its own 7-day
TTL; the dashboard reads empty for one warm cycle and then refills. This is the
only user-visible effect of adoption, and it is worth accepting rather than
carrying the old name — but it should not be a surprise on the day.

## Two things worth deciding before this ships

**The constant is `Cache`, the gem is `estate-utils`.** That is the naming you
asked for and it is what is built. It is worth one more look, because it breaks
the estate's only precedent — `estate-monitor` provides `Estate::Monitor` — and
because a bare top-level `Cache` is a broad constant to claim in a Rails app
that also has `ActiveSupport::Cache` and, in baseball, a
`CacheWarmingController` and a `CacheWarmingService`. `Estate::Utils::Cache::Answers`
is uglier and safer. Either works; the files are laid out so the change is a
`git mv` of `lib/cache*` and one `module` line per file.

**`Cache::Answers.current?` has no callers.** Its comment says "used by the warm
jobs"; it is used by nothing in either app but its own spec. It is carried over
because the extraction should not quietly change behaviour, but it is a
candidate for deletion once somebody confirms it is not wanted.
