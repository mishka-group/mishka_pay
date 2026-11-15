# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CheckoutTest do
  use ExUnit.Case, async: true

  alias GuardedStruct.Errors.Validation
  alias MishkaPay.{Checkout, Customer, Errors, Price}

  # A checkout as a JSON body or a LiveView form gives it: string keys, money as a map.
  @attrs %{
    "provider" => "stripe",
    "items" => [%{"name" => "Ebook", "amount" => %{"amount" => "19.99", "currency" => "usd"}}],
    "success_url" => "https://shop.test/ok",
    "cancel_url" => "https://shop.test/no",
    "reference" => "order-1",
    "customer" => %{"email" => " A@Shop.Test "}
  }

  defp build(changes), do: Errors.from_builder(Checkout.builder(Map.merge(@attrs, changes)))

  defp fields({:error, %Errors.Invalid{errors: errors}}), do: Enum.map(errors, & &1.field)

  test "a checkout from string keys has checked prices, money and customer" do
    assert {:ok, %Checkout{items: [%Price{} = price], customer: %Customer{} = customer}} =
             build(%{})

    assert price.amount == Money.new(:USD, "19.99")
    assert price.quantity == 1
    assert customer.email == "a@shop.test"
  end

  test "a price the provider already knows needs only its id" do
    assert {:ok, %Checkout{items: [%Price{id: "price_1", name: nil}]}} =
             build(%{"items" => [%{"id" => "price_1", "quantity" => 2}]})
  end

  test "no items, mixed currencies or a bad item are refused on items" do
    assert [:items] = fields(build(%{"items" => []}))

    mixed = [
      %{"name" => "a", "amount" => %{"amount" => "1", "currency" => "usd"}},
      %{"name" => "b", "amount" => %{"amount" => "1", "currency" => "EUR"}}
    ]

    assert [:items] = fields(build(%{"items" => mixed}))

    assert {:error, %Errors.Invalid{errors: [%Validation{field: :items, child_errors: [_ | _]}]}} =
             build(%{
               "items" => [%{"name" => "x", "amount" => %{"amount" => 19.9, "currency" => "usd"}}]
             })
  end

  test "a return address must be https, or http on localhost" do
    assert [:success_url] = fields(build(%{"success_url" => "http://shop.test/ok"}))
    assert [:cancel_url] = fields(build(%{"cancel_url" => "javascript:alert(1)"}))
    assert {:ok, _checkout} = build(%{"success_url" => "http://localhost:4000/ok"})
  end

  test "items that are not a list, and metadata that is not strings, are refused" do
    assert [:items] = fields(build(%{"items" => nil}))
    assert [:items] = fields(build(%{"items" => %{"name" => "x"}}))

    for metadata <- [%{"a" => 1}, %{"a" => %{"b" => "c"}}, %{a: "b"}, "x"] do
      assert [:metadata] = fields(build(%{"metadata" => metadata}))
    end
  end

  test "a customer is an id or an email, not both" do
    assert [:customer] = fields(build(%{"customer" => %{"id" => "cus_1", "email" => "a@b.co"}}))
    assert [:customer] = fields(build(%{"customer" => %{}}))
  end

  test "unknown keys and a missing provider are refused" do
    assert [:discount] = fields(build(%{"discount" => "50%"}))

    assert {:error, %Errors.Invalid{}} =
             Errors.from_builder(Checkout.builder(Map.delete(@attrs, "provider")))
  end
end
