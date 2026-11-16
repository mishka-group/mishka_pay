# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Broadcast do
  @moduledoc "A host's broadcast plugin, as `MishkaPay.PubSub` shows it."
  use MishkaPay.PubSub, pubsub: MishkaPay.Support.PubSub
end
