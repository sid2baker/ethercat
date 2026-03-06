defmodule Mix.Tasks.Ethercat.Harness.Doctor do
  use Mix.Task

  @shortdoc "Validate the repo's harness-engineering documentation spine"

  @moduledoc """
  Validate the repository's agent-facing documentation structure.

      mix ethercat.harness.doctor
      mix ethercat.harness.doctor --root /path/to/repo
  """

  @impl true
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [root: :string])
    root = Keyword.get(opts, :root, File.cwd!())

    case EtherCAT.Harness.Doctor.run(root) do
      {:ok, report} ->
        Mix.shell().info("Harness doctor passed.")
        Mix.shell().info("Checked: #{Enum.join(report.checked_paths, ", ")}")

      {:error, report} ->
        Enum.each(Enum.reverse(report.issues), fn issue -> Mix.shell().error(issue) end)
        Mix.raise("Harness doctor found #{length(report.issues)} issue(s)")
    end
  end
end
