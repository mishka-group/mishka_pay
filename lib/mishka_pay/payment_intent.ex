# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.PaymentIntent do
  @moduledoc """
  A payment the site's own page takes with the provider's card form (Stripe Elements), without a
  checkout page: made on the server with `MishkaPay.create_payment_intent/1`, its
  `:client_secret` handed to that buyer's browser, where the provider's script shows the form and
  confirms it. Read with `MishkaPay.fetch_payment_intent/3`, changed before it is paid with
  `MishkaPay.update_payment_intent/1`, confirmed on the server with
  `MishkaPay.confirm_payment_intent/4` (a saved payment method), and ended with
  `MishkaPay.cancel_payment_intent/3`. A guarded_struct.

  Once paid it is a payment like any other: `MishkaPay.fetch_payment/3` reads it by the same
  `:id`, refunds take it, and its webhooks sync the Ash payment row.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:amount` (required to make one): a `Money`, or `%{amount: "19.99", currency: "USD"}`.
    * `:customer_id`: the provider customer who pays (`MishkaPay.create_customer/1`).
    * `:payment_method_id`: a payment method the customer saved, to charge it without the form.
    * `:capture`: `:automatic` (the default) takes the money when it is confirmed, the
      provider's recommended way (Stripe's `automatic_async`); `:automatic_sync` the older way
      (Stripe's `automatic`); `:manual` holds
      it, read as `:requires_capture`, until `MishkaPay.capture_payment/4` takes it or
      `MishkaPay.cancel_payment_intent/3` lets it go.
    * `:setup_future_usage`: `:off_session` keeps the payment method on the customer for later
      charges without the buyer, `:on_session` for later payments the buyer makes.
    * `:automatic_payment_methods`: `true` (the default) offers the payment methods turned on in
      the provider's dashboard; `false` offers cards only.
    * `:description`, `:metadata`: kept with it.
    * `:reference`: the caller's own id for the sale; it makes the idempotency key, so the same
      reference never makes two, and it comes back on the payment. `:owner`: who it is for in the
      caller's app, as on a checkout.

  What the provider fills in:

    * `:id` (`pi_...` at Stripe), `:client_secret`: what the provider's script in the buyer's
      browser takes. Send it only to that buyer's page.
    * `:status`: `:requires_payment_method` (waits for the form), `:requires_confirmation`,
      `:requires_action` (the buyer must pass a check, such as 3D Secure), `:processing`,
      `:requires_capture` (held), `:succeeded` or `:canceled`.
    * `:amount_received`, `:failure_code` and `:failure_message` (why the last try failed),
      `:created_at`.

  A change (`:id` given) names only what it changes.
  """

  use GuardedStruct

  @statuses ~w(requires_payment_method requires_confirmation requires_action processing requires_capture succeeded canceled)a

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}
    field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :payment_method_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :capture, :automatic | :automatic_sync | :manual,
      derives: "validate(enum=Atom[automatic::automatic_sync::manual])",
      validator: {MishkaPay.Checkout, :capture}

    field :setup_future_usage, :on_session | :off_session,
      derives: "validate(enum=Atom[on_session::off_session])",
      validator: {__MODULE__, :usage}

    field :automatic_payment_methods, boolean(), derives: "validate(boolean)"
    field :description, String.t(), derives: "sanitize(trim) validate(string, max_len=1000)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    field :owner, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=200)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :client_secret, String.t(), derives: "validate(string)"

    field :status, atom(),
      derives:
        "validate(enum=Atom[requires_payment_method::requires_confirmation::requires_action::processing::requires_capture::succeeded::canceled])"

    field :amount_received, Money.t(), validator: {MishkaPay.Money, :field}
    field :failure_code, String.t(), derives: "validate(string)"
    field :failure_message, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc "The statuses a payment intent can have."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc false
  def usage(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(on_session off_session)a)
end
