defmodule Tiller.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiller,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Tiller, []},
      extra_applications: [:logger]
    ]
  end

  # The screen for the butterfly lab. Everything in lib/tiller works
  # without these; only lib/tiller_web needs them.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
