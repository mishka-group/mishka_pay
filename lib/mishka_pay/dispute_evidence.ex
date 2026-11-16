# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.DisputeEvidence do
  @moduledoc """
  The answer to a `MishkaPay.Dispute`, given to `MishkaPay.update_dispute/1`. A guarded_struct.

    * `:provider`, `:tenant`, `:dispute_id`: which dispute, with whose keys.
    * `:evidence`: what the seller shows, under the provider's own field names, string keys to
      string values: at Stripe `"product_description"`, `"customer_email_address"`,
      `"service_date"`, `"uncategorized_text"` and the rest of its dispute evidence.
    * `:submit`: `true` sends it to the bank now; left out or `false`, the provider keeps it to
      add more before the due date.
    * `:metadata`: extra pairs kept on the dispute.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :dispute_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    dynamic_field :evidence, validator: {MishkaPay.Checkout, :metadata}
    field :submit, boolean(), derives: "validate(boolean)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
  end
end
