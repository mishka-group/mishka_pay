# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.CheckoutOnly do
  @moduledoc "A provider that takes payments and gives none back: it declares no `:refund`."

  use MishkaPay.Provider, id: "checkout_only", label: "Checkout Only", capabilities: [:checkout]

  @impl MishkaPay.Provider
  def checkout(checkout, _keys),
    do: {:ok, %{checkout | id: "co_1", url: "https://co.test/1", status: :open}}

  @impl MishkaPay.Provider
  def fetch_checkout(id, _keys),
    do:
      {:ok,
       struct(MishkaPay.Checkout, provider: "checkout_only", items: [], id: id, status: :complete)}

  @impl MishkaPay.Provider
  def fetch_payment(id, _keys),
    do:
      MishkaPay.Payment.builder(%{
        provider: "checkout_only",
        id: id,
        amount: Money.new(:USD, 1),
        status: :paid
      })
end
