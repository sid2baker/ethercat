defmodule EtherCAT.Harness.Doctor do
  @moduledoc false

  @required_paths [
    "AGENTS.md",
    "ARCHITECTURE.md",
    "docs/index.md",
    "docs/design-docs/index.md",
    "docs/exec-plans/index.md",
    "docs/exec-plans/tech-debt-tracker.md",
    "docs/QUALITY_SCORE.md",
    "docs/references/README.md"
  ]

  @docs_index_paths [
    "AGENTS.md",
    "ARCHITECTURE.md",
    "docs/design-docs/index.md",
    "docs/exec-plans/index.md",
    "docs/QUALITY_SCORE.md",
    "docs/references/README.md"
  ]

  @max_agents_lines 120

  @type report :: %{
          required_paths: [String.t()],
          checked_paths: [String.t()],
          issues: [String.t()]
        }

  @spec run(String.t()) :: {:ok, report()} | {:error, report()}
  def run(root \\ File.cwd!()) do
    issues =
      []
      |> missing_required_paths(root)
      |> check_agents_lead_section(root)
      |> check_docs_index(root)
      |> check_design_docs_index(root)
      |> check_exec_plans_index(root)

    report = %{
      required_paths: @required_paths,
      checked_paths: checked_paths(root),
      issues: issues
    }

    if issues == [], do: {:ok, report}, else: {:error, report}
  end

  defp missing_required_paths(issues, root) do
    Enum.reduce(@required_paths, issues, fn rel_path, acc ->
      if File.exists?(Path.join(root, rel_path)) do
        acc
      else
        ["missing required path: #{rel_path}" | acc]
      end
    end)
  end

  defp check_agents_lead_section(issues, root) do
    path = Path.join(root, "AGENTS.md")

    if File.exists?(path) do
      lead_section =
        path
        |> File.read!()
        |> String.split("<!-- usage-rules-start -->")
        |> hd()

      line_count = lead_section |> String.split("\n") |> length()

      if line_count <= @max_agents_lines do
        issues
      else
        [
          "AGENTS.md authored section is too large: #{line_count} lines (limit #{@max_agents_lines})"
          | issues
        ]
      end
    else
      issues
    end
  end

  defp check_docs_index(issues, root) do
    index_contains_required_paths(issues, root, "docs/index.md", @docs_index_paths)
  end

  defp check_design_docs_index(issues, root) do
    required =
      wildcard_paths(root, "docs/design-docs/*.md")
      |> Enum.reject(&(&1 == "docs/design-docs/index.md"))

    index_contains_required_paths(issues, root, "docs/design-docs/index.md", required)
  end

  defp check_exec_plans_index(issues, root) do
    required =
      wildcard_paths(root, "docs/exec-plans/active/*.md") ++
        wildcard_paths(root, "docs/exec-plans/completed/*.md") ++
        ["docs/exec-plans/tech-debt-tracker.md"]

    index_contains_required_paths(issues, root, "docs/exec-plans/index.md", required)
  end

  defp index_contains_required_paths(issues, root, index_path, required_paths) do
    full_index_path = Path.join(root, index_path)

    if File.exists?(full_index_path) do
      body = File.read!(full_index_path)

      Enum.reduce(required_paths, issues, fn rel_path, acc ->
        if String.contains?(body, rel_path) do
          acc
        else
          ["#{index_path} is missing entry for #{rel_path}" | acc]
        end
      end)
    else
      issues
    end
  end

  defp wildcard_paths(root, pattern) do
    root
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp checked_paths(root) do
    [
      "AGENTS.md",
      "docs/index.md",
      "docs/design-docs/index.md",
      "docs/exec-plans/index.md"
    ]
    |> Enum.filter(&File.exists?(Path.join(root, &1)))
  end
end
