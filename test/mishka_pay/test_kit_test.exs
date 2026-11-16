# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.TestKitTest do
  # Starts the Stripe plugin and a listener, which every test sees.
  use ExUnit.Case, async: false

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{EventListener, StripeMock}

  @secret "whsec_test_kit"

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_kit", webhook_secret: @secret})
    :ok
  end

  test "a signed event checks out with Stripe's own verification, and a wrong secret does not" do
    object = MishkaPay.Test.stripe_object(:dispute, %{"payment_intent" => "pi_9"})
    {body, headers} = MishkaPay.Test.signed_event("charge.dispute.created", object, @secret)

    {:ok, keys} =
      MishkaPay.Credentials.builder(%{
        provider: "stripe",
        secret_key: "sk",
        webhook_secret: @secret
      })

    assert {:ok, %MishkaPay.Event{dispute_id: "du_test", payment_id: "pi_9"}} =
             Stripe.verify_webhook(body, headers, keys)

    assert {:error, %MishkaPay.Errors.BadSignature{}} =
             Stripe.verify_webhook(body, headers, %{keys | webhook_secret: "whsec_other"})
  end

  test "a delivered event reaches the host's listeners for its tenant" do
    MishkaPay.Test.start_plugin!(EventListener)

    conn =
      MishkaPay.Test.deliver_event(
        "site-a",
        "customer.subscription.updated",
        MishkaPay.Test.stripe_object(:subscription),
        @secret
      )

    assert conn.status == 200

    assert_received {:webhook_event,
                     %MishkaPay.Event{subscription_id: "sub_test", tenant: "site-a"}}

    assert MishkaPay.Test.deliver_event("site-a", "x.y", %{}, "whsec_wrong").status == 400
  end

  @tag :stripe_mock
  test "old test clocks are listed by a dry run and deleted by the task, test keys only" do
    MishkaPay.Test.stub_http(&StripeMock.forward/1)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.MishkaPay.Stripe.CleanClocks.run(["--older-than", "0", "--dry-run"])
    assert_received {:mix_shell, :info, ["would delete clock_" <> _]}

    Mix.Tasks.MishkaPay.Stripe.CleanClocks.run(["--older-than", "0"])
    assert_received {:mix_shell, :info, ["deleted clock_" <> _]}
  end
end
