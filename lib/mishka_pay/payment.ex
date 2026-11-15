# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Payment do
  @moduledoc """
  One payment as the provider sees it: amount, status (`pending`, `paid`, `failed`,
  `refunded`), the provider's id and the time the provider gave. A guarded_struct.

  Stage 2 adds the struct.
  """
end
