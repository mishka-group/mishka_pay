# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.Hidden do
  @moduledoc "An installed provider whose `offered?/0` keeps it out of the offered ones."

  use MishkaPay.Provider, id: "hidden", label: "Hidden Pay"

  @impl MishkaPay.Provider
  def offered?, do: false
end
