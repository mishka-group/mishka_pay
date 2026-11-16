# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.DisputeSync do
  @moduledoc "A host's dispute sync, as `MishkaPay.Ash.Dispute.Listener` shows it."
  use MishkaPay.Ash.Dispute.Listener, resource: MishkaPay.Support.Dispute
end
