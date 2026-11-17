# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.SubscribedTest do
  # Starts the Stripe plugin and shares the sandboxed database with its tasks; Stripe answers
  # through a stub that plays each subscription the test names.
  use MishkaPay.DataCase, async: false

  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{Member, MembersPost, SitePayment, SiteSubscription}

  require Ash.Query

  setup do
    MishkaPay.Test.start_plugin!(Stripe)
    MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a"})
    member = Ash.create!(Member, %{}, authorize?: false)
    %{member: member}
  end

  # Stripe answers each `sub_<status>_<n>` id as a subscription in that status, owned by the
  # `owner` the test gives, with the pro product.
  defp stripe(subscriptions) do
    MishkaPay.Test.stub_http(fn conn ->
      "sub_" <> _ = id = conn.path_info |> List.last()
      Req.Test.json(conn, Map.fetch!(subscriptions, id))
    end)
  end

  defp subscription(id, status, owner, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "object" => "subscription",
        "status" => status,
        "metadata" => %{"mishka_pay_owner" => owner, "plan" => "pro"},
        "created" => 1_794_000_000,
        "items" => %{
          "data" => [
            %{
              "id" => "si_1",
              "quantity" => 1,
              "current_period_start" => 1_794_000_000,
              "current_period_end" => 1_796_000_000,
              "price" => %{
                "id" => "price_pro_month",
                "unit_amount" => 900,
                "currency" => "usd",
                "recurring" => %{"interval" => "month", "interval_count" => 1},
                "product" => %{"id" => "prod_pro", "name" => "Pro"}
              }
            }
          ]
        }
      },
      extra
    )
  end

  defp sync(id, site) do
    Ash.create(SiteSubscription, %{provider: "stripe", subscription_id: id},
      action: :sync,
      tenant: site,
      authorize?: false
    )
  end

  test "a checkout started by a member names them its owner, so the provider keeps who it is for",
       %{member: member} do
    test_pid = self()

    MishkaPay.Test.stub_http(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, URI.decode_query(body)})

      Req.Test.json(conn, %{
        "id" => "cs_1",
        "url" => "https://checkout.stripe.com/c/pay/cs_1",
        "status" => "open"
      })
    end)

    checkout = %{
      provider: "stripe",
      mode: :subscription,
      items: [%{id: "price_pro_month"}],
      success_url: "https://shop.test/thanks",
      cancel_url: "https://shop.test/plans"
    }

    run = fn checkout ->
      SitePayment
      |> Ash.ActionInput.for_action(:start_checkout, %{checkout: checkout},
        tenant: "site-a",
        actor: member
      )
      |> Ash.run_action(authorize?: false)
    end

    assert {:ok, %MishkaPay.Checkout{}} = run.(checkout)
    assert_received {:sent, params}
    assert params["subscription_data[metadata][mishka_pay_owner]"] == member.id

    assert {:ok, %MishkaPay.Checkout{}} = run.(Map.put(checkout, :owner, "gift-for-ava"))
    assert_received {:sent, %{"subscription_data[metadata][mishka_pay_owner]" => "gift-for-ava"}}
  end

  test "a sync writes the owner the provider keeps into the member, and its prices and products",
       %{member: member} do
    stripe(%{
      "sub_active_1" => subscription("sub_active_1", "active", member.id),
      "sub_active_2" => subscription("sub_active_2", "active", "not-a-member-id")
    })

    assert {:ok, row} = sync("sub_active_1", "site-a")

    assert {row.user_id, row.price_ids, row.product_ids} ==
             {member.id, ["price_pro_month"], ["prod_pro"]}

    assert {:ok, %{user_id: nil}} = sync("sub_active_2", "site-a")
  end

  test "with PayPal too, the member who started the checkout owns the subscription and has access",
       %{member: member} do
    MishkaPay.Test.start_plugin!(MishkaPay.Providers.PayPal)

    MishkaPay.Test.put_keys("paypal", %{
      publishable_key: "client_a",
      secret_key: "secret_a",
      mode: :test
    })

    MishkaPay.Test.PayPal.stub!()

    {:ok, %MishkaPay.Checkout{id: id}} =
      SitePayment
      |> Ash.ActionInput.for_action(
        :start_checkout,
        %{
          checkout: %{
            provider: "paypal",
            mode: :subscription,
            items: [%{name: "Pro", amount: %{amount: "9", currency: "USD"}, interval: :month}],
            success_url: "https://shop.test/thanks",
            cancel_url: "https://shop.test/plans",
            reference: "pro-1"
          }
        },
        tenant: "site-a",
        actor: member
      )
      |> Ash.run_action(authorize?: false)

    MishkaPay.Test.PayPal.subscription(id, "ACTIVE")

    assert {:ok, %{user_id: user_id}} =
             Ash.create(SiteSubscription, %{provider: "paypal", subscription_id: id},
               action: :sync,
               tenant: "site-a",
               authorize?: false
             )

    assert user_id == member.id
    assert MishkaPay.Ash.subscribed?(SiteSubscription, member, tenant: "site-a")
    refute MishkaPay.Ash.subscribed?(SiteSubscription, member, tenant: "site-b")
  end

  test "access follows the subscription's status, trial, product and site", %{member: member} do
    past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_unix()
    later = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()

    stripe(%{
      "sub_active_1" => subscription("sub_active_1", "active", member.id),
      "sub_trialing_1" =>
        subscription("sub_trialing_1", "trialing", member.id, %{"trial_end" => later}),
      "sub_trialing_2" =>
        subscription("sub_trialing_2", "trialing", member.id, %{"trial_end" => past}),
      "sub_past_due_1" => subscription("sub_past_due_1", "past_due", member.id),
      "sub_canceled_1" => subscription("sub_canceled_1", "canceled", member.id),
      "sub_active_9" =>
        subscription("sub_active_9", "active", member.id, %{"cancel_at_period_end" => true})
    })

    other = Ash.create!(Member, %{}, authorize?: false)
    subscribed? = &MishkaPay.Ash.subscribed?(SiteSubscription, &1, &2)

    refute subscribed?.(member, tenant: "site-a")

    for id <- ["sub_canceled_1", "sub_trialing_2"] do
      {:ok, _row} = sync(id, "site-a")
      refute subscribed?.(member, tenant: "site-a"), id
    end

    {:ok, _row} = sync("sub_past_due_1", "site-a")
    refute subscribed?.(member, tenant: "site-a")
    assert subscribed?.(member, tenant: "site-a", statuses: [:active, :trialing, :past_due])

    {:ok, _row} = sync("sub_trialing_1", "site-a")
    assert subscribed?.(member, tenant: "site-a")
    assert subscribed?.(member.id, tenant: "site-a", product: "prod_pro")
    assert subscribed?.(member, tenant: "site-a", price: ["price_team", "price_pro_month"])
    refute subscribed?.(member, tenant: "site-a", product: "prod_team")

    rows =
      Ash.read!(SiteSubscription,
        tenant: "site-a",
        authorize?: false,
        load: [:active?, :on_trial?, :canceling?]
      )

    assert rows |> Enum.filter(& &1.active?) |> Enum.map(& &1.provider_id) == ["sub_trialing_1"]
    assert rows |> Enum.filter(& &1.on_trial?) |> Enum.map(& &1.provider_id) == ["sub_trialing_1"]

    assert [%{provider_id: "sub_trialing_1"}] =
             SiteSubscription
             |> Ash.Query.filter(active?)
             |> Ash.read!(tenant: "site-a", authorize?: false)

    {:ok, ending} = sync("sub_active_9", "site-c")

    assert %{active?: true, canceling?: true, on_trial?: false} =
             Ash.load!(ending, [:active?, :canceling?, :on_trial?], tenant: "site-c")

    {:ok, _row} = sync("sub_active_1", "site-b")
    assert subscribed?.(member, tenant: "site-b")
    refute subscribed?.(other, tenant: "site-a")
    refute subscribed?.(nil, tenant: "site-a")
    refute subscribed?.(member, tenant: "site-d")
  end

  test "as a policy, a members-only post is read only by a member with access in that site",
       %{member: member} do
    stripe(%{"sub_active_1" => subscription("sub_active_1", "active", member.id)})
    other = Ash.create!(Member, %{}, authorize?: false)
    {:ok, _row} = sync("sub_active_1", "site-a")
    Ash.create!(MembersPost, %{title: "Members only"}, tenant: "site-a")

    assert {:ok, [%{title: "Members only"}]} =
             Ash.read(MembersPost, actor: member, tenant: "site-a")

    assert {:ok, [_post]} = Ash.read(MembersPost, action: :pro, actor: member, tenant: "site-a")

    # A read policy filters: who has no access reads nothing.
    for {actor, site} <- [{other, "site-a"}, {nil, "site-a"}, {member, "site-b"}] do
      assert {:ok, []} = Ash.read(MembersPost, actor: actor, tenant: site)
    end
  end

  test "a slow read of the provider that ends after a newer one never overwrites it",
       %{member: member} do
    test_pid = self()

    # The first read is held until the second has written; then it answers what it read before.
    MishkaPay.Test.stub_http(fn conn ->
      case Process.get(:slow) do
        true ->
          send(test_pid, {:reading, self()})
          assert_receive :answer
          Req.Test.json(conn, subscription("sub_active_1", "active", member.id))

        _fast ->
          Req.Test.json(conn, subscription("sub_active_1", "canceled", member.id))
      end
    end)

    slow =
      Task.async(fn ->
        Process.put(:slow, true)
        sync("sub_active_1", "site-a")
      end)

    assert_receive {:reading, reader}
    assert {:ok, %{status: :canceled}} = sync("sub_active_1", "site-a")
    send(reader, :answer)

    assert {:error, error} = Task.await(slow)
    assert MishkaPay.Ash.stale?(error)

    assert [%{status: :canceled}] =
             Ash.read!(SiteSubscription, tenant: "site-a", authorize?: false)

    refute MishkaPay.Ash.subscribed?(SiteSubscription, member, tenant: "site-a")
  end
end
