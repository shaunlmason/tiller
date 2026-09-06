#!/bin/sh
# Build a throwaway open-seed instantiation on the fastcards (local SQLite)
# backend so the integration tests can run against the real engine with no
# remote, no credentials, and no state ref to push.
#
#   test/support/seed_fixture.sh <open-seed-checkout> <seed-binary> <out-dir>
#
# then:
#
#   TILLER_SEED_CMD="<seed-binary> mcp serve" TILLER_SEED_DIR=<out-dir> \
#     mix test --include integration
set -eu
[ $# -eq 3 ] || { echo "usage: $0 <open-seed-checkout> <seed-binary> <out-dir>" >&2; exit 64; }
src=$1; seed=$2; out=$3
rm -rf "$out"; mkdir -p "$out"; cd "$out"
git init -q
cp -r "$src/.seed" .
# fastcards: machine-local, transactional, needs no remote (§7.3 amendment).
sed -i.bak 's/^backend = "filecards"/backend = "fastcards"/' .seed/config.toml
# the tests' actor doubles as an operator so it can promote its own cards.
sed -i.bak 's/^actors = \[/actors = ["tiller", /' .seed/config.toml
rm -f .seed/config.toml.bak
git add -A
git -c user.email=fixture@tiller -c user.name=fixture commit -qm "seed fixture"
"$seed" init --actor tiller >/dev/null
echo "$out"
