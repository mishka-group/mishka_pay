defmodule Shop.Pay.KeysTest do
  # Changes the process environment the keys are read from.
  use ShopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Shop.Pay.{Keys, WebhookSimulator}

  @names ~w(STRIPE_WEBHOOK_SECRET STRIPE_WEBHOOK_SECRET_OLD)

  setup do
    saved = Map.new(@names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  test "the secrets from before a roll come from STRIPE_WEBHOOK_SECRET_OLD, several with commas" do
    System.put_env("STRIPE_WEBHOOK_SECRET", "whsec_new_for_test")
    System.delete_env("STRIPE_WEBHOOK_SECRET_OLD")
    assert Keys.old_webhook_secrets() == []
    refute List.keymember?(WebhookSimulator.situations(), :rolled_secret, 0)

    System.put_env("STRIPE_WEBHOOK_SECRET_OLD", "whsec_old_a, whsec_old_b")
    assert Keys.old_webhook_secrets() == ["whsec_old_a", "whsec_old_b"]
    assert List.keymember?(WebhookSimulator.situations(), :rolled_secret, 0)
  end

  test "with the simulator's own secret, its own old one stands in, so a roll can be shown" do
    Enum.each(@names, &System.delete_env/1)

    assert Keys.local_webhook_secret?()
    assert [old] = Keys.old_webhook_secrets()
    refute old == Keys.webhook_secret()
    assert List.keymember?(WebhookSimulator.situations(), :rolled_secret, 0)
  end

  test "the Site card always says how many secrets from before a roll are taken, 0 when none",
       %{conn: conn} do
    ShopWeb.StripeStub.stub(fn _method, _path, _params -> nil end)
    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("[data-testid=site-webhook-old-secrets]") |> render() =~
             "0 from before"

    MishkaPay.Test.put_keys(
      "stripe",
      %{secret_key: "sk_test_shop", webhook_secret: "whsec_new", webhook_secrets: ["whsec_old"]},
      "demo"
    )

    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("[data-testid=site-webhook-old-secrets]") |> render() =~
             "1 from before"
  end
end
