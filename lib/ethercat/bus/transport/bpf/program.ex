defmodule EtherCAT.Bus.Transport.Bpf.Program do
  @moduledoc false

  # Cache only builds created by this VM, never a path discovered on disk. The
  # lock keeps concurrent opens from compiling or publishing the same revision.
  @spec ensure(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure(source) do
    with {:ok, contents} <- File.read(source) do
      :global.trans(
        {{__MODULE__, source}, self()},
        fn ->
          cached_or_build(source, contents)
        end,
        [node()]
      )
    end
  end

  defp cached_or_build(source, contents) do
    key = {__MODULE__, source}

    case :persistent_term.get(key, nil) do
      {^contents, program} ->
        if File.regular?(program), do: {:ok, program}, else: build_and_cache(key, contents)

      _missing_or_changed ->
        build_and_cache(key, contents)
    end
  end

  defp build_and_cache(key, contents) do
    with {:ok, program} <- build(contents) do
      :persistent_term.put(key, {contents, program})
      {:ok, program}
    end
  end

  defp build(contents) do
    case System.find_executable("cc") do
      nil -> {:error, :no_c_compiler}
      cc -> build_in_private_directory(cc, contents)
    end
  end

  defp build_in_private_directory(cc, contents) do
    # mktemp creates the directory atomically with mode 0700. mkdir followed by
    # chmod leaves a window in which another user can plant files or symlinks.
    template = Path.join(System.tmp_dir!(), "ethercat-bpf.XXXXXXXXXX")

    case System.cmd("mktemp", ["-d", template], stderr_to_stdout: true) do
      {directory, 0} -> compile(cc, String.trim(directory), contents)
      {output, _status} -> {:error, {:bpf_build_failed, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:bpf_build_failed, error.original}}
  end

  defp compile(cc, directory, contents) do
    source = Path.join(directory, "ethercat_bpf.c")
    program = Path.join(directory, "ethercat_bpf")

    result =
      with :ok <- File.write(source, contents),
           {_output, 0} <- System.cmd(cc, ["-O2", "-o", program, source], stderr_to_stdout: true) do
        {:ok, program}
      else
        {:error, reason} -> {:error, {:bpf_build_failed, reason}}
        {output, _status} -> {:error, {:bpf_build_failed, String.trim(output)}}
      end

    case result do
      {:ok, _program} ->
        result

      {:error, _reason} ->
        File.rm_rf(directory)
        result
    end
  rescue
    error in ErlangError ->
      File.rm_rf(directory)
      {:error, {:bpf_build_failed, error.original}}
  end
end
