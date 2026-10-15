defmodule EtherCAT.Bus.Transport.Bpf.ProgramTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Bus.Transport.Bpf.Program

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    source = Path.join(directory, "helper.c")
    File.write!(source, "#include <stdio.h>\nint main(void) { puts(\"trusted\"); return 0; }\n")
    %{source: source}
  end

  test "builds in an owner-only directory and ignores planted executables", %{source: source} do
    beside_source = Path.rootname(source)

    predictable =
      Path.join(System.tmp_dir!(), "ethercat_bpf-#{:erlang.phash2(File.read!(source))}")

    planted = "#!/bin/sh\necho untrusted\n"
    File.write!(beside_source, planted)
    File.ln_s!(beside_source, predictable)
    on_exit(fn -> File.rm(predictable) end)

    assert {:ok, program} = Program.ensure(source)
    on_exit(fn -> File.rm_rf(Path.dirname(program)) end)
    refute program in [beside_source, predictable]
    assert {"trusted\n", 0} = System.cmd(program, [])
    assert File.read!(beside_source) == planted
    assert {:ok, ^beside_source} = File.read_link(predictable)
    assert %{type: :directory, mode: mode} = File.lstat!(Path.dirname(program))
    assert String.ends_with?(Integer.to_string(mode, 8), "700")
    assert {:ok, ^program} = Program.ensure(source)
  end

  test "concurrent callers reuse only a completed build", %{source: source} do
    results =
      1..8
      |> Task.async_stream(fn _ -> Program.ensure(source) end, max_concurrency: 8)
      |> Enum.to_list()

    assert [{:ok, {:ok, program}}] = Enum.uniq(results)
    on_exit(fn -> File.rm_rf(Path.dirname(program)) end)
    assert {"trusted\n", 0} = System.cmd(program, [])
  end

  test "changed source is rebuilt even with the same modification time", %{source: source} do
    assert {:ok, first} = Program.ensure(source)
    %{mtime: mtime} = File.stat!(source)
    File.write!(source, "#include <stdio.h>\nint main(void) { puts(\"changed\"); return 0; }\n")
    File.touch!(source, mtime)
    assert {:ok, second} = Program.ensure(source)
    on_exit(fn -> Enum.each([first, second], &File.rm_rf(Path.dirname(&1))) end)
    refute second == first
    assert {"changed\n", 0} = System.cmd(second, [])
  end

  test "compiler failures are returned and not cached", %{source: source} do
    File.write!(source, "this is not C")
    assert {:error, {:bpf_build_failed, message}} = Program.ensure(source)
    assert is_binary(message)
    File.write!(source, "int main(void) { return 0; }\n")
    assert {:ok, program} = Program.ensure(source)
    on_exit(fn -> File.rm_rf(Path.dirname(program)) end)
    assert {"", 0} = System.cmd(program, [])
  end

  test "missing sources are returned as errors", %{source: source} do
    File.rm!(source)
    assert Program.ensure(source) == {:error, :enoent}
  end
end
