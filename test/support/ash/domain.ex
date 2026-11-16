# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Domain do
  @moduledoc "A host's payments domain, holding the resources the Ash layer tests use."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource MishkaPay.Support.WebhookEvent
    resource MishkaPay.Support.Payment
    resource MishkaPay.Support.Subscription
    resource MishkaPay.Support.Customer
    resource MishkaPay.Support.Dispute
  end
end
