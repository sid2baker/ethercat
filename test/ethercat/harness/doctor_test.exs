defmodule EtherCAT.Harness.DoctorTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Harness.Doctor

  test "passes for a complete harness spine" do
    root = tmp_root()

    write_file(root, "AGENTS.md", """
    # Repo Guide
    Short guide.
    <!-- usage-rules-start -->
    generated
    """)

    write_file(root, "ARCHITECTURE.md", "# Architecture\n")
    write_file(root, "docs/references/README.md", "# References\n")
    write_file(root, "docs/exec-plans/tech-debt-tracker.md", "# Debt\n")
    write_file(root, "docs/design-docs/alpha.md", "# Alpha\n")
    write_file(root, "docs/design-docs/index.md", "docs/design-docs/alpha.md\n")
    write_file(root, "docs/exec-plans/active/plan-a.md", "# Plan A\n")
    write_file(root, "docs/exec-plans/completed/plan-b.md", "# Plan B\n")

    write_file(
      root,
      "docs/exec-plans/index.md",
      """
      docs/exec-plans/active/plan-a.md
      docs/exec-plans/completed/plan-b.md
      docs/exec-plans/tech-debt-tracker.md
      """
    )

    write_file(root, "docs/QUALITY_SCORE.md", "# Quality\n")

    write_file(
      root,
      "docs/index.md",
      """
      AGENTS.md
      ARCHITECTURE.md
      docs/design-docs/index.md
      docs/exec-plans/index.md
      docs/QUALITY_SCORE.md
      docs/references/README.md
      """
    )

    assert {:ok, %{issues: []}} = Doctor.run(root)
  end

  test "fails when design docs index is stale" do
    root = tmp_root()

    write_minimal_spine(root)
    write_file(root, "docs/design-docs/new-doc.md", "# New\n")

    assert {:error, %{issues: issues}} = Doctor.run(root)

    assert Enum.any?(
             issues,
             &String.contains?(
               &1,
               "docs/design-docs/index.md is missing entry for docs/design-docs/new-doc.md"
             )
           )
  end

  test "fails when AGENTS authored section is too large" do
    root = tmp_root()
    long_body = Enum.map_join(1..130, "\n", fn idx -> "line #{idx}" end)

    write_minimal_spine(root)

    write_file(
      root,
      "AGENTS.md",
      """
      #{long_body}
      <!-- usage-rules-start -->
      generated
      """
    )

    assert {:error, %{issues: issues}} = Doctor.run(root)
    assert Enum.any?(issues, &String.contains?(&1, "AGENTS.md authored section is too large"))
  end

  defp write_minimal_spine(root) do
    write_file(root, "AGENTS.md", "# Guide\n<!-- usage-rules-start -->\n")
    write_file(root, "ARCHITECTURE.md", "# Architecture\n")
    write_file(root, "docs/references/README.md", "# References\n")
    write_file(root, "docs/exec-plans/tech-debt-tracker.md", "# Debt\n")
    write_file(root, "docs/design-docs/index.md", "# Design Index\n")
    write_file(root, "docs/exec-plans/index.md", "docs/exec-plans/tech-debt-tracker.md\n")
    write_file(root, "docs/QUALITY_SCORE.md", "# Quality\n")

    write_file(
      root,
      "docs/index.md",
      """
      AGENTS.md
      ARCHITECTURE.md
      docs/design-docs/index.md
      docs/exec-plans/index.md
      docs/QUALITY_SCORE.md
      docs/references/README.md
      """
    )
  end

  defp write_file(root, rel_path, body) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp tmp_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "ethercat-harness-doctor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end
end
