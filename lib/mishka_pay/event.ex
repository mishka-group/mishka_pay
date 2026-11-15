# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Event do
  @moduledoc """
  A provider's webhook message after its signature was checked: provider, the
  provider's event id, type, the object it is about and when the provider made it. Only the ids
  matter: the handler fetches the object again from the provider, which stays the source of truth.

  Stage 3 adds the struct.
  """
end
