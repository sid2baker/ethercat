defmodule EtherCAT.MixProject do
  use Mix.Project

  @source_url "https://github.com/sid2baker/ethercat"

  def project do
    [
      app: :ethercat,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      docs: docs(),
      usage_rules: usage_rules(),
      source_url: @source_url
    ]
  end

  def application do
    [
      mod: {EtherCAT.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:vintage_net, "~> 0.13"},
      {:ex_doc, "~> 0.36", only: :dev, runtime: false},
      {:usage_rules, "~> 1.1", only: [:dev]}
    ]
  end

  defp description do
    "Pure-Elixir EtherCAT master built on OTP. Declarative bus configuration, " <>
      "cyclic process data exchange, CoE SDO transfers, and distributed clocks."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "EtherCAT",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:elixir, :otp],
      skills: [
        build: [
          "elixir-otp": [
            description:
              "Use this skill when working with standard Elixir and OTP — GenServer, supervisors, processes, streams, pattern matching, etc.",
            usage_rules: [:usage_rules]
          ]
        ]
      ]
    ]
  end
end
