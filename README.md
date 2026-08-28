# estate-utils

Shared caching for answers that cost real money or real seconds to produce —
a model completion, a scrape, a warehouse query.

It is not a general-purpose cache. Rails has one of those and this is built on
it. This is the layer above: the decision about whether an answer needs
producing again at all.

Extracted from baseball and football, where the same file lived twice and was
byte-identical once the comments were stripped.

## Why not just a TTL

A TTL is a guess about freshness, and the guess costs whoever asks next. Too
short and the same answer is rebuilt for nothing; too long and it is wrong.
Neither dial has a good setting when a rebuild takes 102 seconds.

So two things instead:

**A fingerprint.** The caller says what the answer is *about* — a game's score
and quarter, a warehouse build stamp, whatever cheap signal actually moves when
the answer should. If it has not moved, the existing answer is re-leased rather
than rebuilt. A nil fingerprint always rebuilds: unknown inputs must never read
as unchanged.

**A last-good copy.** Every write also lands under a key that no version change
invalidates, kept for seven days. A reader that misses the current version gets
the previous answer immediately, marked stale, and a job rebuilds it. Nobody
waits for a generation on the request path.

## Usage

```ruby
Cache.refresh_job = RefreshCachedInsightJob   # in an initializer

# In a service
Cache::Answers.resolve("game_insights:#{id}", ttl: 10.minutes,
                       fingerprint: state_fingerprint(id)) { generate(id) }

# In a controller
include Cache::ServesAnswers
serve_cached(Cache::Answers.read("game_insights:#{id}"),
             kind: "game_insights:#{id}", refresh: params[:refresh].present?)
```

`resolve_detailed` returns `{ value:, outcome: }` where outcome is one of
`:served`, `:kept`, `:generated`, `:failed` — a Cached/Fresh badge renders off
it, and only `:generated` is honestly fresh.

## Cache::Warehouse

The build-stamped variant: the stamp goes into the key, so a rebuild
invalidates the answer and the value can be held for hours without ever being
stale.

```ruby
Cache::Warehouse.stamp_provider = -> { Warehouse::Manager.build_stamp }
Cache::Warehouse.resolve("depth_movers", ttl: 6.hours) { generate }
```

Nobody uses it yet. It is separated out because it is the mechanism
`Warehouse::Cached` was *named* for, while everything actually using that module
was caching model answers against a TTL — see MIGRATION.md.

## Cache::AnswerLog

What the cache did, per answer name: generated / kept / served / failed counts,
the last error, the last duration.

`summary[:never_kept]` is the line worth watching. A fingerprint that never
matches spends a completion on every warm run and looks, from the outside,
exactly like a healthy cache — same pages, same answers, same latency, just a
bill. This is its only symptom.

## Configuration

| | Default | |
| --- | --- | --- |
| `Cache.store` | `Rails.cache` | read through, not memoised, so swapping `Rails.cache` works |
| `Cache.logger` | `Rails.logger` | |
| `Cache.refresh_job` | warns | must respond to `enqueue_once(kind)` |
| `Cache::Warehouse.stamp_provider` | raises | only needed if you use `Cache::Warehouse` |

The specs run with no Rails at all, which is the standing proof that these are
real seams rather than decoration.

```
bundle install && bundle exec rspec
```
