# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers.Stripe.TestClockTest do
  # Starts the Stripe plugin, which changes the providers event every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.Errors
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Providers.Stripe.TestClock
  alias MishkaPay.Support.StripeMock

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_123"})
    :ok
  end

  describe "against Stripe's mock server" do
    @describetag :stripe_mock

    setup do
      MishkaPay.Test.stub_http(&StripeMock.forward/1)
    end

    test "a clock is made, read, moved forward, listed and deleted" do
      at = ~U[2026-11-16 10:00:00Z]

      assert {:ok, %TestClock{id: "clock_" <> _ = id}} =
               TestClock.create("site-a", at: at, name: "renewal")

      assert {:ok, %TestClock{id: ^id}} = TestClock.fetch("site-a", id)

      assert {:ok, %TestClock{}} =
               TestClock.advance("site-a", id, DateTime.add(at, 32, :day))

      assert {:ok, [%TestClock{} | _]} = TestClock.list("site-a")
      assert :ok = TestClock.delete("site-a", id)
    end
  end

  test "live keys never reach Stripe from here, whatever their mode says" do
    MishkaPay.Test.stub_http(fn _conn -> raise "no request may be sent" end)

    for keys <- [
          %{secret_key: "sk_test_123", mode: :live},
          %{secret_key: "sk_live_123"},
          %{secret_key: "rk_live_123"}
        ] do
      MishkaPay.Test.put_keys("stripe", keys)

      assert {:error, %Errors.Unsupported{operation: "test clock with live keys"}} =
               TestClock.create("site-a")
    end
  end

  test "an id that is not a clock id never reaches a path" do
    assert {:error, %Errors.Invalid{errors: [%{field: :clock_id}]}} =
             TestClock.fetch("site-a", "clock_1/../../v1/charges")

    assert {:error, %Errors.Invalid{errors: [%{field: :clock_id}]}} =
             TestClock.advance("site-a", "sub_1", DateTime.utc_now())
  end
end
