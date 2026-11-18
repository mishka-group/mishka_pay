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

  `:flow` opens the page on one task instead of its home, and sends the buyer back to
  `:return_url` when it is done: `:subscription_cancel` or `:subscription_update` (with
  `:subscription_id`), or `:payment_method_update` (the card on file).

  What the provider fills in: `:id` and `:url`. The link is short-lived: make one per click.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :flow_fits} do
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

    field :flow, :subscription_cancel | :subscription_update | :payment_method_update,
      derives:
        "validate(enum=Atom[subscription_cancel::subscription_update::payment_method_update])",
      validator: {__MODULE__, :flow}

    field :subscription_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :id, String.t(), derives: "validate(string)"
    field :url, String.t(), derives: "validate(string)"
  end

  @doc false
  def flow(field, value),
    do:
      MishkaPay.Helpers.Choice.atom(
        field,
        value,
        ~w(subscription_cancel subscription_update payment_method_update)a
      )

  # A subscription flow names its subscription.
  @doc false
  def flow_fits(attrs) do
    flow = attrs |> value(:flow) |> to_string()

    case {flow in ~w(subscription_cancel subscription_update),
          is_binary(value(attrs, :subscription_id))} do
      {true, false} ->
        {:error,
         %{
           field: :subscription_id,
           action: :flow,
           message: MishkaPay.Messages.text(:customer_needs, field: :subscription_id)
         }}

      _fits ->
        {:ok, attrs}
    end
  end

  defp value(attrs, name), do: Map.get(attrs, name) || Map.get(attrs, Atom.to_string(name))
end

defmodule MishkaPay.PortalSession.Configuration do
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
      `:promotion_code`; `[]` nothing. With `:price`, `:plans` (`MishkaPay.PortalSession.Configuration.Plans`) lists the
      products and prices they may switch to, and `:proration` says how the change bills:
      `:create_prorations`, `:always_invoice` or `:none`.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id` (`bpc_...` at Stripe), `:default` (`true` for the one a
  session without `:configuration` uses), `:created_at`.

  ## Plans

  Each of `:plans` is a `MishkaPay.PortalSession.Configuration.Plans`, a sub_field of this struct:
  a product a buyer may switch their subscription to in the customer portal, with the prices of
  it on offer.

    * `:product_id`: the catalog product (`MishkaPay.Product`).
    * `:price_ids`: its recurring prices the buyer may pick, one or more.
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

    sub_field :plans, [MishkaPay.PortalSession.Configuration.Plans.t()],
      structs: true,
      authorized_fields: true,
      derives: "validate(list)" do
      field :product_id, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

      field :price_ids, list(),
        enforce: true,
        derives: "validate(not_nil_value, list, not_empty, each=[string, not_empty])"
    end

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
