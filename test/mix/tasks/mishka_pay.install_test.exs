# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "a Phoenix project gets the provider, its keys plugin, the webhook plug and the test config" do
    phx_test_project()
    |> Igniter.compose_task("mishka_pay.install", [])
    |> assert_creates("lib/test/pay/keys.ex")
    |> assert_has_patch("lib/test/application.ex", """
    + |      MishkaPay.Providers.Stripe,
    """)
    |> assert_has_patch("config/test.exs", """
    + |config :mishka_pay, req_options: [plug: {Req.Test, MishkaPay.Client}]
    """)
    |> assert_has_patch("config/config.exs", """
    + |config :ex_money, auto_start_exchange_rate_service: false
    """)
  end

  test "the webhook plug goes right before Plug.Parsers, and running it again changes nothing" do
    igniter =
      phx_test_project()
      |> Igniter.compose_task("mishka_pay.install", [])
      |> apply_igniter!()

    endpoint =
      igniter.rewrite
      |> Rewrite.source!("lib/test_web/endpoint.ex")
      |> Rewrite.Source.get(:content)

    [before_parsers, _after] = String.split(endpoint, ~r/plug\(?\s*Plug\.Parsers/, parts: 2)
    assert before_parsers =~ ~r/plug\(?MishkaPay\.Webhook, at: "\/pay\/webhooks"\)?/

    igniter
    |> Igniter.compose_task("mishka_pay.install", [])
    |> assert_unchanged()
  end

  test "--ash adds the domain, the five resources and their listeners; --pubsub the broadcast" do
    igniter =
      phx_test_project()
      |> Igniter.compose_task("mishka_pay.install", ["--ash", "--pubsub"])
      |> assert_creates("lib/test/pay.ex")
      |> assert_creates("lib/test/pay/webhook_event.ex")
      |> assert_creates("lib/test/pay/broadcast.ex")
      |> assert_has_patch("lib/test/application.ex", """
      + |      Test.Pay.Dispute.MishkaPayListener,
      """)

    payment =
      igniter.rewrite
      |> Rewrite.source!("lib/test/pay/payment.ex")
      |> Rewrite.Source.get(:content)

    assert payment =~ "extensions: [MishkaPay.Ash.Resource]"
    assert payment =~ ~r/mishka_pay do\s+kind[( ]:payment\)?\s+end/
    refute Rewrite.has_source?(igniter.rewrite, "lib/test/pay/payment_sync.ex")
  end
end
