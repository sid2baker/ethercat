defmodule EthercatTest do
  use ExUnit.Case
  doctest Ethercat

  test "greets the world" do
    assert Ethercat.hello() == :world
  end
end
