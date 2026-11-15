# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPayTest do
  use ExUnit.Case
  doctest MishkaPay

  test "greets the world" do
    assert MishkaPay.hello() == :world
  end
end
