Application.ensure_all_started(:tiller)

# Integration tests need a real engine: set TILLER_SEED_CMD (argv for
# `seed mcp serve`) and TILLER_SEED_DIR (an instantiated repo; see
# test/support/seed_fixture.sh) and run `mix test --include integration`.
# Live tests call the real Claude API: `mix test --include live` with
# ANTHROPIC_API_KEY set.
ExUnit.start(exclude: [:integration, :live])
