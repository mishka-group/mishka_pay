# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.SetupIntent do
  @moduledoc """
  A payment method saved for later on the site's own page, with the provider's card form (Stripe
  Elements) and no charge: made on the server with `MishkaPay.create_setup_intent/1`, its
  `:client_secret` handed to that buyer's browser, where the provider's script shows the form and
  confirms it. Read with `MishkaPay.fetch_setup_intent/3`, confirmed on the server with
  `MishkaPay.confirm_setup_intent/4`, and ended with `MishkaPay.cancel_setup_intent/3`. Once it
  succeeded, its `:payment_method_id` is on the customer: `MishkaPay.list_payment_methods/3`
  lists it. A guarded_struct.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:customer_id`: the provider customer who keeps the payment method. Without one, the
      payment method is saved but on no customer, and can be used once.
    * `:payment_method_id`: a payment method to save, to confirm it without the form.
    * `:usage`: `:off_session` (the provider's default) for later charges without the buyer,
      `:on_session` for later payments the buyer makes.
    * `:automatic_payment_methods`: `true` (the default) offers the payment methods turned on in
      the provider's dashboard; `false` offers cards only.
    * `:description`, `:metadata`: kept with it.
    * `:reference`: the caller's own id for it; it makes the idempotency key, so the same
      reference never makes two, and it comes back on it.

  What the provider fills in: `:id` (`seti_...` at Stripe), `:client_secret` (send it only to
  that buyer's page), `:status` (`:requires_payment_method`, `:requires_confirmation`,
  `:requires_action`, `:processing`, `:succeeded` or `:canceled`), `:failure_code`,
  `:failure_message` and `:created_at`.
  """

  use GuardedStruct

  @statuses ~w(requires_payment_method requires_confirmation requires_action processing succeeded canceled)a

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :customer_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :payment_method_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"

    field :usage, :on_session | :off_session,
      derives: "validate(enum=Atom[on_session::off_session])",
      validator: {MishkaPay.PaymentIntent, :usage}

    field :automatic_payment_methods, boolean(), derives: "validate(boolean)"
    field :description, String.t(), derives: "sanitize(trim) validate(string, max_len=1000)"

    field :reference, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :client_secret, String.t(), derives: "validate(string)"

    field :status, atom(),
      derives:
        "validate(enum=Atom[requires_payment_method::requires_confirmation::requires_action::processing::succeeded::canceled])"

    field :failure_code, String.t(), derives: "validate(string)"
    field :failure_message, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end

  @doc "The statuses a setup intent can have."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
