# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PortalSession do
  @moduledoc """
  A link to the provider's own billing page for one customer (Stripe's customer portal), made with
  `MishkaPay.portal_session/1`. Send the buyer to `:url`; there they update their card, see their
  invoices, and change or cancel their plan as the provider's settings allow, then come back to
  `:return_url`. What they change reaches the host through its webhooks. A guarded_struct.

  What the caller gives: `:provider`, `:tenant`, `:customer_id`, `:return_url` (`https`, or `http`
  on `localhost`), and optionally `:configuration`, the provider's id of a portal setup other than
  its default.

  What the provider fills in: `:id` and `:url`. The link is short-lived: make one per click.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :customer_id, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :return_url, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)",
      validator: {MishkaPay.Checkout, :return_url}

    field :configuration, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :id, String.t(), derives: "validate(string)"
    field :url, String.t(), derives: "validate(string)"
  end
end
