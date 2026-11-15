# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.Broken do
  @moduledoc "A provider whose `offered?/0` raises."

  use MishkaPay.Provider, id: "broken", label: "Broken Pay"

  @impl MishkaPay.Provider
  def offered?, do: raise("the settings store is down")
end
