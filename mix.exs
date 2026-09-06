defmodule Tiller.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiller,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # test/support holds scripts and fixtures, not test modules
      test_ignore_filters: [~r"^test/support/"],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Tiller, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  # Phoenix arrived with the butterfly lab's LiveView (design premise 5).
  # No Ecto, no asset pipeline: the LiveView JS is served straight from the
  # deps' priv/static, so the project still needs nothing but mix.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.7"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
