defmodule Jido.Chat.Teams.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_chat_teams"
  @description "Microsoft Teams adapter package for Jido.Chat"

  def project do
    [
      app: :jido_chat_teams,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Jido Chat Teams",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls, summary: [threshold: 0], export: "cov"]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl]]
  end

  def cli do
    [
      preferred_envs: [
        quality: :test,
        q: :test,
        cover: :test,
        coveralls: :test,
        "test.contracts": :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jido_chat, path: "../jido_chat"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
      q: ["quality"],
      cover: ["coveralls"],
      "test.contracts": [
        "test test/jido/chat/teams/adapter_test.exs test/jido/chat/teams/webhook_test.exs"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "test"
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "appPackage", "mix.exs", "README.md", "LICENSE", "usage-rules.md", "docs"],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Discord" => "https://jido.run/discord",
        "Documentation" => "https://hexdocs.pm/jido_chat_teams",
        "GitHub" => @source_url,
        "Website" => "https://jido.run"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "usage-rules.md", "docs/architecture.md", "docs/validation.md"]
    ]
  end
end
