# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.SubscriptionSync do
  @moduledoc "A host's subscription sync, as `MishkaPay.Ash.Subscription.Listener` shows it."

  use MishkaPay.Ash.Subscription.Listener, resource: MishkaPay.Support.Subscription
end
