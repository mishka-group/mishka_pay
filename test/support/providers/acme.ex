# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Acme do
  @moduledoc """
  A provider written by a project, as the docs of `MishkaPay.Provider` show it. It keeps nothing
  and calls nothing: its answers come from what it is given, so tests can tell each path apart.

    * A checkout whose reference is `"decline"` is declined; any other opens at a page named after
      the reference.
    * A payment id says its own status: `"acme_paid"`, `"acme_pending"`.
    * Every operation answers only with the keys `"sk_acme"`.
  """

  use MishkaPay.Provider,
    id: "acme",
    label: "Acme Pay",
    capabilities: [:checkout, :refund],
    priority: 10

  alias MishkaPay.{Checkout, Errors, Payment, Refund}

  @impl MishkaPay.Provider
  def checkout(%Checkout{reference: "decline"}, _keys),
    do: {:error, Errors.Declined.exception(provider: "acme", reason: "card_declined")}

  def checkout(%Checkout{} = checkout, %{secret_key: "sk_acme"}) do
    {:ok,
     %{
       checkout
       | id: "acme_cs_#{checkout.reference}",
         url: "https://pay.acme.test/#{checkout.reference}",
         status: :open
     }}
  end

  def checkout(_checkout, _keys),
    do: {:error, Errors.Declined.exception(provider: "acme", reason: "bad_keys")}

  @impl MishkaPay.Provider
  def fetch_checkout("acme_cs_" <> reference = id, %{secret_key: "sk_acme"}) do
    {:ok,
     %Checkout{
       provider: "acme",
       items: [],
       success_url: nil,
       cancel_url: nil,
       id: id,
       reference: reference,
       status: :complete,
       payment_id: "acme_paid"
     }}
  end

  @impl MishkaPay.Provider
  def fetch_payment("acme_" <> status = id, %{secret_key: "sk_acme"}) do
    Payment.builder(%{
      provider: "acme",
      id: id,
      amount: Elixir.Money.new(:USD, "19.99"),
      status: String.to_existing_atom(status)
    })
  end

  @impl MishkaPay.Provider
  def refund(%Refund{} = refund, %{secret_key: "sk_acme"}),
    do: {:ok, %{refund | id: "acme_re_1", status: :succeeded}}
end
