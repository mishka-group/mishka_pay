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
    * A subscription id says its own status: `"acme_sub_active"`, `"acme_sub_trialing"`.
    * Every operation answers only with the keys `"sk_acme"`.
  """

  use MishkaPay.Provider,
    id: "acme",
    label: "Acme Pay",
    capabilities: [:checkout, :refund, :subscription],
    priority: 10

  alias MishkaPay.{Checkout, Errors, Invoice, Payment, Refund, Subscription}

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
     struct(Checkout,
       provider: "acme",
       items: [],
       id: id,
       reference: reference,
       status: :complete,
       payment_id: "acme_paid"
     )}
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

  @impl MishkaPay.Provider
  def fetch_subscription("acme_sub_" <> status = id, %{secret_key: "sk_acme"}),
    do: subscription(id, String.to_existing_atom(status), false)

  @impl MishkaPay.Provider
  def cancel_subscription(id, :now, %{secret_key: "sk_acme"}),
    do: subscription(id, :canceled, false)

  def cancel_subscription(id, :period_end, %{secret_key: "sk_acme"}),
    do: subscription(id, :active, true)

  @impl MishkaPay.Provider
  def resume_subscription(id, %{secret_key: "sk_acme"}), do: subscription(id, :active, false)

  @impl MishkaPay.Provider
  def list_invoices(id, %{secret_key: "sk_acme"}) do
    with {:ok, invoice} <-
           Invoice.builder(%{
             provider: "acme",
             id: "acme_in_1",
             subscription_id: id,
             status: :paid,
             amount_due: Elixir.Money.new(:USD, "9.00"),
             amount_paid: Elixir.Money.new(:USD, "9.00")
           }),
         do: {:ok, [invoice]}
  end

  defp subscription(id, status, cancel_at_period_end) do
    Subscription.builder(%{
      provider: "acme",
      id: id,
      status: status,
      cancel_at_period_end: cancel_at_period_end,
      items: [%{name: "Pro plan", amount: Elixir.Money.new(:USD, "9.00"), interval: :month}]
    })
  end
end
