defmodule EtherCAT.MixProject do
  use Mix.Project

  def project do
    [
      app: :ethercat,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      usage_rules: usage_rules()
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
      {:telemetry_metrics, "~> 1.0"},
      {:usage_rules, "~> 1.1", only: [:dev]}
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: :all
    ]
  end
end
