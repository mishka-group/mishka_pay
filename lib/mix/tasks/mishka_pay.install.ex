# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.Install.Docs do
  @moduledoc false

  def short_doc, do: "Sets a Phoenix project up to take payments with Mishka Pay"

  def example, do: "mix igniter.install mishka_pay --ash --pubsub"

  def long_doc do
    """
    #{short_doc()}.

        #{example()}

    It adds, and never twice:

      * the Stripe provider and a keys plugin (`<App>.Pay.Keys`) to the application's children;
        the keys plugin answers each site's Stripe keys at runtime, from the environment until the
        project keeps them per site;
      * the webhook endpoint (`plug MishkaPay.Webhook, at: "/pay/webhooks"`) before
        `Plug.Parsers` in the endpoint, which needs the raw body;
      * the test config that lets `MishkaPay.Test.stub_http/1` answer every provider call, and
        `config :ex_money, auto_start_exchange_rate_service: false` (Mishka Pay converts no
        currencies).

    Options:

      * `--ash`: the Ash layer: a `<App>.Pay` domain with the webhook inbox, payments,
        subscriptions, customers and disputes as resources of the project, their listeners, and
        the inbox's Oban queue. It needs ash_postgres and ash_oban (`mix igniter.install ash_postgres
        ash_oban`), then `mix ash.codegen mishka_pay`.
      * `--pubsub`: `<App>.Pay.Broadcast`, Mishka Pay's PubSub plugin on the project's
        `<App>.PubSub`.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.MishkaPay.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Application, Config}

    @resources [
      {"WebhookEvent", MishkaPay.Ash.Inbox, "pay_webhook_events", "Inbox"},
      {"Payment", MishkaPay.Ash.Payment, "pay_payments", "PaymentSync"},
      {"Subscription", MishkaPay.Ash.Subscription, "pay_subscriptions", "SubscriptionSync"},
      {"Customer", MishkaPay.Ash.Customer, "pay_customers", "CustomerSync"},
      {"Dispute", MishkaPay.Ash.Dispute, "pay_disputes", "DisputeSync"}
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :mishka_pay,
        example: __MODULE__.Docs.example(),
        schema: [ash: :boolean, pubsub: :boolean],
        defaults: [ash: false, pubsub: false]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      app_name = Application.app_name(igniter)
      keys = Igniter.Project.Module.module_name(igniter, "Pay.Keys")

      igniter
      |> Igniter.Project.Module.create_module(keys, keys_module(), on_exists: :skip)
      |> Application.add_new_child(MishkaPay.Providers.Stripe)
      |> Application.add_new_child(keys, after: [MishkaPay.Providers.Stripe])
      |> webhook_plug()
      |> Config.configure_new(
        "test.exs",
        :mishka_pay,
        [:req_options],
        plug: {Req.Test, MishkaPay.Client}
      )
      |> Config.configure_new(
        "config.exs",
        :ex_money,
        [:auto_start_exchange_rate_service],
        false
      )
      |> then(&if(options[:ash], do: ash(&1, app_name), else: &1))
      |> then(&if(options[:pubsub], do: pubsub(&1), else: &1))
      |> Igniter.add_notice("""
      Mishka Pay is set up.

        * Give the keys: STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET (test keys outside production),
          or answer each site's own in #{inspect(keys)}.
        * Point Stripe's webhook to https://<your host>/pay/webhooks/stripe/<tenant> and send it the
          events in MishkaPay.Providers.Stripe.handled_events/0.
        * Open a checkout: MishkaPay.checkout(%{provider: "stripe", ...}).
      """)
    end

    defp keys_module do
      """
      @moduledoc \"\"\"
      Answers Mishka Pay's keys for each provider and tenant (a site), at runtime. Here every tenant
      has the keys of the environment; a project with many sites answers each site's own (from its
      database or settings), and `nil` for a site without keys.
      \"\"\"

      use MishkaPay.Credentials

      @impl MishkaPay.Credentials
      def credentials("stripe", _tenant) do
        case System.get_env("STRIPE_SECRET_KEY") do
          nil ->
            nil

          key ->
            %{
              secret_key: key,
              webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
              mode: if(String.starts_with?(key, "sk_live_"), do: :live, else: :test)
            }
        end
      end

      def credentials(_provider, _tenant), do: nil
      """
    end

    # The webhook needs the raw body: its plug goes right before `Plug.Parsers`, once.
    defp webhook_plug(igniter) do
      case Igniter.Libs.Phoenix.select_endpoint(igniter) do
        {igniter, nil} ->
          Igniter.add_warning(igniter, """
          No Phoenix endpoint was found. Add `plug MishkaPay.Webhook, at: "/pay/webhooks"` before
          `Plug.Parsers` in the endpoint that takes the webhooks.
          """)

        {igniter, endpoint} ->
          Igniter.Project.Module.find_and_update_module!(igniter, endpoint, &add_webhook_plug/1)
      end
    end

    defp add_webhook_plug(zipper) do
      webhook? =
        Function.move_to_function_call_in_current_scope(
          zipper,
          :plug,
          [1, 2],
          &Function.argument_equals?(&1, 0, MishkaPay.Webhook)
        )

      parsers =
        Function.move_to_function_call_in_current_scope(
          zipper,
          :plug,
          [1, 2],
          &Function.argument_equals?(&1, 0, Plug.Parsers)
        )

      case {webhook?, parsers} do
        {{:ok, _found}, _parsers} ->
          {:ok, zipper}

        {:error, {:ok, parsers}} ->
          {:ok,
           Common.add_code(
             parsers,
             ~s|plug MishkaPay.Webhook, at: "/pay/webhooks"|,
             placement: :before
           )}

        {:error, :error} ->
          {:warning,
           ~s|No Plug.Parsers in the endpoint: add `plug MishkaPay.Webhook, at: "/pay/webhooks"` before the plug that reads the body.|}
      end
    end

    defp ash(igniter, app_name) do
      domain = Igniter.Project.Module.module_name(igniter, "Pay")
      repo = Igniter.Project.Module.module_name(igniter, "Repo")

      igniter =
        Enum.reduce(@resources, igniter, fn {name, fragment, table, listener}, igniter ->
          resource = Module.concat(domain, name)

          igniter
          |> Igniter.Project.Module.create_module(
            resource,
            resource_body(domain, fragment, table, repo),
            on_exists: :skip
          )
          |> Igniter.Project.Module.create_module(
            Module.concat(domain, listener),
            listener_body(fragment, resource),
            on_exists: :skip
          )
          |> Application.add_new_child(Module.concat(domain, listener),
            after: [MishkaPay.Providers.Stripe]
          )
        end)

      igniter
      |> Igniter.Project.Module.create_module(domain, domain_body(domain), on_exists: :skip)
      |> Config.configure_new("config.exs", app_name, [:ash_domains], [])
      |> Config.configure(
        "config.exs",
        app_name,
        [:ash_domains],
        [domain],
        updater: &Igniter.Code.List.append_new_to_list(&1, domain)
      )
      |> Config.configure(
        "config.exs",
        app_name,
        [Oban, :queues, :mishka_pay_inbox],
        5
      )
      |> Igniter.add_notice("""
      Mishka Pay's Ash layer is in #{inspect(domain)}: run `mix ash.codegen mishka_pay` and migrate.
      It needs ash_postgres and ash_oban (`mix igniter.install ash_postgres ash_oban`).
      """)
    end

    defp resource_body(domain, fragment, table, repo) do
      """
      use Ash.Resource,
        domain: #{inspect(domain)},
        data_layer: AshPostgres.DataLayer,
        fragments: [#{inspect(fragment)}]

      postgres do
        table "#{table}"
        repo #{inspect(repo)}
      end
      """
    end

    defp listener_body(MishkaPay.Ash.Inbox, resource),
      do: "use MishkaPay.Ash.Inbox.Listener, resource: #{inspect(resource)}"

    defp listener_body(fragment, resource),
      do: "use #{inspect(fragment)}.Listener, resource: #{inspect(resource)}"

    defp domain_body(domain) do
      resources =
        Enum.map_join(@resources, "\n", fn {name, _f, _t, _l} ->
          "    resource #{inspect(Module.concat(domain, name))}"
        end)

      """
      use Ash.Domain

      resources do
      #{resources}
      end
      """
    end

    defp pubsub(igniter) do
      broadcast = Igniter.Project.Module.module_name(igniter, "Pay.Broadcast")
      pubsub = Igniter.Project.Module.module_name(igniter, "PubSub")

      igniter
      |> Igniter.Project.Module.create_module(
        broadcast,
        "use MishkaPay.PubSub, pubsub: #{inspect(pubsub)}",
        on_exists: :skip
      )
      |> Application.add_new_child(broadcast, after: [Phoenix.PubSub])
    end
  end
end
