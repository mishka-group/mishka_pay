# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Event do
  @moduledoc """
  A provider's webhook message after its signature was checked, as `MishkaPay.Webhook` hands it
  to the `mishka_pay:webhook:received` listeners. A guarded_struct the provider fills in.

    * `:provider`, `:tenant`: whose message, with whose keys it was checked.
    * `:id`: the provider's event id (`evt_...` at Stripe). A provider may send one event more
      than once: a listener keeps what it did by this id.
    * `:type`: the provider's own name for what happened, such as `"checkout.session.completed"`.
    * `:object_id`, `:object_type`: what it is about (`"pi_..."`, `"payment_intent"`).
    * `:livemode`: whether it came from live or test mode.
    * `:account`: the connected account it is for, when the provider has those.
    * `:created_at`: when the provider made it.

  Only the ids matter: a listener reads the object again from the provider
  (`MishkaPay.fetch_payment/3`), which stays the source of truth, and never trusts the order
  events arrive in.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :tenant, term()
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :type, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :object_id, String.t(), derives: "validate(string)"
    field :object_type, String.t(), derives: "validate(string)"
    field :livemode, boolean(), default: false, derives: "validate(boolean)"
    field :account, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end
