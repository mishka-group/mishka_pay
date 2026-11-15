# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.Acme do
  @moduledoc "A provider written by a project, as the docs of `MishkaPay.Provider` show it."

  use MishkaPay.Provider,
    id: "acme",
    label: "Acme Pay",
    capabilities: [:checkout, :refund],
    priority: 10
end
