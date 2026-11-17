# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PortalConfiguration do
  @moduledoc """
  What buyers may do in the provider's customer portal (`MishkaPay.PortalSession`), kept at the
  provider as one setup a portal session names by `:configuration`: a site can keep one for
  monthly buyers and another for teams. Made with `MishkaPay.create_portal_configuration/1`,
  changed with `MishkaPay.update_portal_configuration/1`, read with
  `MishkaPay.fetch_portal_configuration/3` and `MishkaPay.list_portal_configurations/3`. A
  guarded_struct.

  What the caller gives, every field optional (a change sends only what it names):

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:name`: the host's own name for it; `:active`: `false` turns it off (a provider never
      deletes one).
    * The portal page's header: `:headline`, `:privacy_policy_url`, `:terms_of_service_url`; and
      `:default_return_url`, where buyers go back when a session names no `return_url`.
    * `:invoice_history`: `true` shows their past bills; `:payment_method_update`: `true` lets
      them change their card.
    * `:customer_update`: which of their details they may change, from `:email`, `:address`,
      `:shipping`, `:phone`, `:tax_id`, `:name`; `[]` none.
    * `:subscription_cancel`: `:immediately`, `:at_period_end`, or `:off`.
    * `:subscription_update`: what they may change on a plan, from `:price`, `:quantity`,
      `:promotion_code`; `[]` nothing. With `:price`, `:plans` (`MishkaPay.PortalPlan`) lists the
      products and prices they may switch to, and `:proration` says how the change bills:
      `:create_prorations`, `:always_invoice` or `:none`.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id` (`bpc_...` at Stripe), `:default` (`true` for the one a
  session without `:configuration` uses), `:created_at`.
  """

  use GuardedStruct

  alias MishkaPay.Helpers.Choice

  @customer_fields [:email, :address, :shipping, :phone, :tax_id, :name]
  @plan_fields [:price, :quantity, :promotion_code]

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=256)"
    field :active, boolean(), derives: "validate(boolean)"
    field :default, boolean(), derives: "validate(boolean)"
    field :headline, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=60)"
    field :privacy_policy_url, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :terms_of_service_url, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :default_return_url, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :invoice_history, boolean(), derives: "validate(boolean)"
    field :payment_method_update, boolean(), derives: "validate(boolean)"
    field :customer_update, list(), validator: {__MODULE__, :customer_update}

    field :subscription_cancel, :off | :immediately | :at_period_end,
      derives: "validate(enum=Atom[off::immediately::at_period_end])",
      validator: {__MODULE__, :subscription_cancel}

    field :subscription_update, list(), validator: {__MODULE__, :subscription_update}
    field :plans, list(), structs: MishkaPay.PortalPlan, derives: "validate(list)"

    field :proration, :create_prorations | :always_invoice | :none,
      derives: "validate(enum=Atom[create_prorations::always_invoice::none])",
      validator: {__MODULE__, :proration}

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc false
  def customer_update(field, value), do: Choice.atoms(field, value, @customer_fields)

  @doc false
  def subscription_update(field, value), do: Choice.atoms(field, value, @plan_fields)

  @doc false
  def subscription_cancel(field, value),
    do: Choice.atom(field, value, ~w(off immediately at_period_end)a)

  @doc false
  def proration(field, value),
    do: Choice.atom(field, value, ~w(create_prorations always_invoice none)a)
end
