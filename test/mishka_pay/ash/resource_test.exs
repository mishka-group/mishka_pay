# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Ash.ResourceTest do
  # Starts plugins and shares the sandboxed database with their tasks; Stripe answers through
  # Stripe's own mock server.
  use MishkaPay.DataCase, async: false

  alias Ash.Resource.Info, as: AshInfo
  alias MishkaPay.Ash.Resource.{ApplyKind, Info, Kinds}
  alias MishkaPay.Providers.Stripe
  alias MishkaPay.Support.{Domain, PaymentWatcher, StripeMock, WebhookEvent}
  alias MishkaPay.Support.Options.{Kept, Located, Owned, Quiet, User}

  defp action_names(resource), do: resource |> AshInfo.actions() |> Enum.map(& &1.name)

  describe "kind" do
    test "a resource gets every action of its kind, the primary read and the kind's shape" do
      for {resource, kind} <- [
            {WebhookEvent, :inbox},
            {MishkaPay.Support.Payment, :payment},
            {MishkaPay.Support.Subscription, :subscription},
            {MishkaPay.Support.Customer, :customer},
            {MishkaPay.Support.Dispute, :dispute}
          ] do
        assert Info.mishka_pay_kind!(resource) == kind
        assert Enum.sort(action_names(resource)) == Enum.sort([:read | Kinds.action_names(kind)])
        assert AshInfo.primary_action(resource, :read).name == :read

        assert AshInfo.primary_key(resource) == [:id]
        assert AshInfo.attribute(resource, :id).type == Ash.Type.UUIDv7

        assert AshInfo.attribute(resource, :inserted_at)

        {identity, keys} = Kinds.identity(kind)
        assert %{keys: ^keys} = AshInfo.identity(resource, identity)
      end
    end

    test "the inbox's trigger is named after its resource" do
      assert [trigger] = AshOban.Info.oban_triggers(WebhookEvent)
      assert trigger.worker_module_name == WebhookEvent.MishkaPayWorker
      assert trigger.scheduler_module_name == WebhookEvent.MishkaPayScheduler
      assert trigger.on_error == :fail
    end
  end

  describe "actions" do
    test "only the chosen actions are added, besides the primary read" do
      assert Enum.sort(action_names(Quiet)) == [:read, :sync]
      assert Info.actions(Quiet) == [:sync]
      assert Info.actions(MishkaPay.Support.Payment) == Kinds.action_names(:payment)
    end

    test "an action the kind does not have is a compile error that names the kind's actions" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          compile(quote(do: [kind: :payment, actions: [:sync, :cancel]]))
        end

      assert error.message =~ ":cancel is not an action of the :payment kind"
      assert error.message =~ ":sync, :start_checkout, :refund"
    end

    test "an inbox without all of its actions is a compile error" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          compile(quote(do: [kind: :inbox, actions: [:receive]]))
        end

      assert error.message =~ "An :inbox works only with all of its actions"
    end

    test "an inbox in a project without AshOban is refused with what to add" do
      dsl =
        update_in(
          WebhookEvent.spark_dsl_config(),
          [:persist, :spark_extensions],
          &List.delete(&1, AshOban)
        )

      assert {:error, %Spark.Error.DslError{message: message}} = ApplyKind.transform(dsl)
      assert message =~ "ash_oban"
    end

    test "tenant_from needs the host's own attribute, and is not for an inbox" do
      assert_raise Spark.Error.DslError,
                   ~r/tenant_from :site_id: .* has no such attribute/s,
                   fn ->
                     compile(quote(do: [kind: :payment, tenant_from: :site_id]))
                   end

      assert_raise Spark.Error.DslError, ~r/An :inbox stays global/, fn ->
        compile(quote(do: [kind: :inbox, tenant_from: :site_id]))
      end
    end

    test "a resource without a kind is a compile error" do
      assert_raise Spark.Error.DslError, ~r/without a kind/, fn -> compile([]) end
    end
  end

  describe "listen?" do
    test "a listener is made for each resource that listens, and listed for its domain" do
      assert Info.listener(MishkaPay.Support.Payment) ==
               MishkaPay.Support.Payment.MishkaPayListener

      assert Code.ensure_loaded?(MishkaPay.Support.Payment.MishkaPayListener)

      assert MishkaPay.Ash.listeners(Domain) == [
               WebhookEvent.MishkaPayListener,
               MishkaPay.Support.Payment.MishkaPayListener,
               MishkaPay.Support.Subscription.MishkaPayListener,
               MishkaPay.Support.Customer.MishkaPayListener,
               MishkaPay.Support.Dispute.MishkaPayListener,
               MishkaPay.Support.SitePayment.MishkaPayListener
             ]
    end

    test "listen? false makes no listener" do
      assert Info.listener(Quiet) == nil
      refute Code.ensure_loaded?(Quiet.MishkaPayListener)

      assert MishkaPay.Ash.listeners(MishkaPay.Support.Options) == [
               Owned.MishkaPayListener,
               Kept.MishkaPayListener
             ]
    end
  end

  describe "announce? and code_interface?" do
    @describetag :stripe_mock

    setup do
      MishkaPay.Test.start_plugin!(Stripe)
      MishkaPay.Test.start_plugin!(PaymentWatcher)
      MishkaPay.Test.put_keys("stripe", %{secret_key: "sk_test_a"})
      MishkaPay.Test.stub_http(&StripeMock.forward/1)
      :ok
    end

    test "the code interface syncs, and the sync announces the change" do
      assert {:ok, %{provider_id: "pi_123"}} =
               MishkaPay.Support.Payment.sync(
                 %{provider: "stripe", payment_id: "pi_123", tenant: "site-a"},
                 authorize?: false
               )

      assert_received {:payment_changed, %MishkaPay.Payment{id: "pi_123"}, _record}
    end

    test "announce? false writes the row without announcing it" do
      assert {:ok, %{provider_id: "pi_123"}} =
               Ash.create(Quiet, %{provider: "stripe", payment_id: "pi_123"},
                 action: :sync,
                 authorize?: false
               )

      refute_received {:payment_changed, _payment, _record}
    end

    test "tenant_from writes each create's tenant into the host's own attribute too" do
      site = Ash.UUID.generate()

      assert {:ok, %{site_id: ^site, tenant: ^site}} =
               Ash.create(Located, %{provider: "stripe", payment_id: "pi_123", tenant: site},
                 action: :sync,
                 authorize?: false
               )
    end

    test "code_interface? false defines no functions; the default defines one per action" do
      Enum.each([Quiet, Owned, Kept, WebhookEvent], &Code.ensure_loaded!/1)
      refute Info.mishka_pay_code_interface?(Quiet)
      assert Info.mishka_pay_code_interface?(Owned)
      refute function_exported?(Quiet, :sync, 1)
      assert function_exported?(Owned, :cancel!, 1)
      assert function_exported?(Owned, :change, 2)
      assert function_exported?(Kept, :accept, 1)
      assert function_exported?(WebhookEvent, :receive_event, 1)
    end
  end

  describe "belongs_to_user and what the host defines" do
    test "belongs_to_user adds a :user relationship on :user_id, or on the attribute given" do
      assert %{destination: User, source_attribute: :user_id, allow_nil?: true} =
               AshInfo.relationship(Owned, :user)

      assert %{destination: User, source_attribute: :owner_id} = AshInfo.relationship(Kept, :user)
      assert AshInfo.attribute(Kept, :owner_id)
      refute AshInfo.relationship(Quiet, :user)
    end

    test "an attribute, identity or action the host defines is kept as the host wrote it" do
      assert %{allow_nil?: false, default: "basic"} = AshInfo.attribute(Owned, :plan)

      assert %{pre_check_with: MishkaPay.Support.Options} =
               AshInfo.identity(Kept, :provider_dispute)

      assert :rename in action_names(Owned)
    end
  end

  defp compile(options) do
    name = Module.concat(__MODULE__, "Compiled#{System.unique_integer([:positive])}")

    section =
      case options do
        [] ->
          nil

        options ->
          {:mishka_pay, [],
           [[do: {:__block__, [], for({key, value} <- options, do: {key, [], [value]})}]]}
      end

    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use Ash.Resource,
            domain: MishkaPay.Support.Options,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [MishkaPay.Ash.Resource]

          unquote(section)
        end
      end
    )
  end
end
