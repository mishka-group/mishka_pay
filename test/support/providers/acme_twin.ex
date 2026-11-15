# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.AcmeTwin do
  @moduledoc "A second provider with the id of `MishkaPay.Test.Acme`, later on the event."

  use MishkaPay.Provider, id: "acme", label: "Acme Pay copy", priority: 60
end
