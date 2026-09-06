#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# The web container has no Erlang or Elixir. Fetch prebuilt builds from
# builds.hex.pm (no compile step), install hex and rebar, fetch and compile
# the project's deps, and export the toolchain into the session's
# environment so `mix test`, `mix format` and `mix phx.server` work from
# the first turn. Idempotent: an installed toolchain is reused, and the
# container state is cached after the hook completes.
#
# Local machines use mise.toml instead; this script exits at once there.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

OTP_VERSION="${TILLER_OTP_VERSION:-28.5.0.6}"
ELIXIR_VERSION="${TILLER_ELIXIR_VERSION:-1.20.4}"
TOOLCHAIN="${TILLER_TOOLCHAIN_DIR:-$HOME/.tiller-toolchain}"

OTP_MAJOR="${OTP_VERSION%%.*}"
OTP_DIR="$TOOLCHAIN/otp-$OTP_VERSION"
ELIXIR_DIR="$TOOLCHAIN/elixir-$ELIXIR_VERSION-otp-$OTP_MAJOR"

# builds.hex.pm publishes OTP per Ubuntu release; match the container.
UBUNTU_VERSION="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-24.04}")"
OTP_URL="https://builds.hex.pm/builds/otp/ubuntu-${UBUNTU_VERSION}/OTP-${OTP_VERSION}.tar.gz"
ELIXIR_URL="https://builds.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-${OTP_MAJOR}.zip"

mkdir -p "$TOOLCHAIN"

if [ ! -x "$OTP_DIR/bin/erl" ]; then
  echo "session-start: installing OTP $OTP_VERSION (ubuntu-$UBUNTU_VERSION)"
  rm -rf "$OTP_DIR" "$OTP_DIR.tmp"
  mkdir -p "$OTP_DIR.tmp"
  curl -fsSL "$OTP_URL" | tar -xz -C "$OTP_DIR.tmp" --strip-components=1
  (cd "$OTP_DIR.tmp" && ./Install -minimal "$OTP_DIR.tmp" >/dev/null)
  mv "$OTP_DIR.tmp" "$OTP_DIR"
fi

if [ ! -x "$ELIXIR_DIR/bin/elixir" ]; then
  echo "session-start: installing Elixir $ELIXIR_VERSION (otp-$OTP_MAJOR)"
  rm -rf "$ELIXIR_DIR" "$ELIXIR_DIR.tmp"
  mkdir -p "$ELIXIR_DIR.tmp"
  curl -fsSL -o "$ELIXIR_DIR.tmp/elixir.zip" "$ELIXIR_URL"
  (cd "$ELIXIR_DIR.tmp" && unzip -q elixir.zip && rm elixir.zip)
  mv "$ELIXIR_DIR.tmp" "$ELIXIR_DIR"
fi

export PATH="$ELIXIR_DIR/bin:$OTP_DIR/bin:$PATH"
# The container's locale is not UTF-8, which Elixir warns about on every run.
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export ELIXIR_ERL_OPTIONS="+fnu"

echo "session-start: $(elixir --version 2>/dev/null | tail -1)"

mix local.hex --force --if-missing >/dev/null
mix local.rebar --force >/dev/null

cd "$CLAUDE_PROJECT_DIR"
mix deps.get
# Warm both build dirs so the first `mix test` and `mix phx.server` are fast.
mix compile
MIX_ENV=test mix compile

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$ELIXIR_DIR/bin:$OTP_DIR/bin:\$PATH\""
    echo "export LANG=\"$LANG\""
    echo "export LC_ALL=\"$LC_ALL\""
    echo "export ELIXIR_ERL_OPTIONS=\"+fnu\""
  } >> "$CLAUDE_ENV_FILE"
fi

echo "session-start: ready"
