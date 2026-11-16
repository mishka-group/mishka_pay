# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Entitlement do
  @moduledoc """
  A customer's access to a `MishkaPay.Feature` right now, given by a product they bought, read
  with `MishkaPay.list_entitlements/4`. A guarded_struct the provider fills in.

    * `:provider`, `:id`: the provider's id of the entitlement.
    * `:feature_id`: the feature it gives.
    * `:lookup_key`: the feature's lookup key, which the host checks access by.

  The provider keeps the list current as subscriptions start and end, and sends a webhook when it
  changes (`entitlements.active_entitlement_summary.updated` at Stripe).
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string)"
    field :id, String.t(), derives: "validate(string)"
    field :feature_id, String.t(), derives: "validate(string)"
    field :lookup_key, String.t(), derives: "validate(string)"
  end
end
