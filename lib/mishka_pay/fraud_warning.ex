# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.FraudWarning do
  @moduledoc """
  A card issuer's early warning that a payment looks like fraud (an early fraud warning,
  `issfr_...` at Stripe Radar), often days before the buyer's bank opens a dispute. A guarded_struct
  the provider fills in, read with `MishkaPay.fetch_fraud_warning/3` and
  `MishkaPay.list_fraud_warnings/3`.

    * `:id`, `:payment_id`, `:charge_id`: the warning and the payment it is about.
    * `:fraud_type`: the issuer's kind of fraud, in the provider's words
      (`"made_with_stolen_card"`, `"unauthorized_use_of_card"`, `"card_never_received"`...).
    * `:actionable`: whether a refund can still head off a dispute: the payment is not refunded
      or disputed yet. Refunding an actionable warning's payment in full usually stops the
      dispute and its fee.
    * `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :payment_id, String.t(), derives: "validate(string)"
    field :charge_id, String.t(), derives: "validate(string)"
    field :fraud_type, String.t(), derives: "validate(string)"
    field :actionable, boolean(), default: false, derives: "validate(boolean)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end
