defmodule EtherCAT.MixProject do
  use Mix.Project

  @version "0.4.2"
  @source_url "https://github.com/sid2baker/ethercat"

  def project do
    [
      app: :ethercat,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r|^test/integration/hardware/scripts/|],
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
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

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/integration/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.36", only: :dev, runtime: false},
      {:usage_rules, "~> 1.1", only: [:dev]},
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false}
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
      extras: ["README.md", "CHANGELOG.md"],
      before_closing_head_tag: &before_closing_head_tag/1
    ]
  end

  defp aliases do
    [
      "docs.fresh": ["compile --force", "docs"]
    ]
  end

  defp before_closing_head_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }

        let id = 0;

        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;

          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_head_tag(_format), do: ""

  defp usage_rules do
    [
      file: "AGENTS.md",
      # The built-in :elixir / :otp aliases also inline usage_rules.md.
      # Use explicit sub-rules here so AGENTS.md only gets the Elixir and OTP sections.
      usage_rules: [
        {:usage_rules, main: false, sub_rules: ["elixir", "otp"]}
      ]
    ]
  end
end
