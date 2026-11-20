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

      * `MishkaPay.Registry` first, which starts mishka_installer's plugin registry when nothing else
        does (as in a project's test run), then a keys plugin (`<App>.Pay.Keys`) to the application's children;
        the keys plugin answers each site's Stripe keys at runtime, from the environment until the
        project keeps them per site;
      * the webhook endpoint (`plug MishkaPay.Webhook, at: "/pay/webhooks"`) before
        `Plug.Parsers` in the endpoint, which needs the raw body;
      * `MishkaPay.Test.setup!/0` and `MishkaPay.Test.await_plugin!/1` before `ExUnit.start()`, so
        tests start once Stripe is registered;
      * mishka_installer's plugin registry in `.mnesia/<env>` (left out of git), where providers,
        keys and listeners are kept;
      * the test config that lets `MishkaPay.Test.stub_http/1` answer every provider call, and
        `config :ex_money, auto_start_exchange_rate_service: false` (Mishka Pay converts no
        currencies).

    Options:

      * `--ash`: the Ash layer: a `<App>.Pay` domain with the webhook inbox, the count of refused
        webhook messages, payments, subscriptions, customers and disputes as resources of the project
        (`MishkaPay.Ash.Resource`), the listener the extension makes for each in the application's
        children, the inbox's Oban queue, `config :ash, default_string_length_count: :codepoints`
        when the project has no such setting, and `:mishka_pay` in the formatter's `import_deps`
        (its DSL is written without parentheses). It needs ash_postgres and ash_oban
        (`mix igniter.install ash_postgres ash_oban`), then `mix ash.codegen mishka_pay`.
      * `--admin`: with `--ash` (which it turns on), the provider objects a site manages from its
        admin as resources too: products, prices, coupons, promotion codes, payment links and
        bills, each synced by its webhooks (`MishkaPay.Ash.Object.Spec`). Run it again on a
        project installed without it to add them.
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
      {"WebhookEvent", :inbox, "pay_webhook_events"},
      {"WebhookRejection", :webhook_rejection, "pay_webhook_rejections"},
      {"Payment", :payment, "pay_payments"},
      {"Subscription", :subscription, "pay_subscriptions"},
      {"Customer", :customer, "pay_customers"},
      {"Dispute", :dispute, "pay_disputes"}
    ]

    @admin_resources [
      {"Product", :product, "pay_products"},
      {"Price", :price, "pay_prices"},
      {"Coupon", :coupon, "pay_coupons"},
      {"PromotionCode", :promotion_code, "pay_promotion_codes"},
      {"PaymentLink", :payment_link, "pay_payment_links"},
      {"Invoice", :invoice, "pay_invoices"}
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :mishka_pay,
        example: __MODULE__.Docs.example(),
        schema: [ash: :boolean, admin: :boolean, pubsub: :boolean],
        defaults: [ash: false, admin: false, pubsub: false]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      app_name = Application.app_name(igniter)
      keys = Igniter.Project.Module.module_name(igniter, "Pay.Keys")

      igniter
      |> create_once(keys, keys_module())
      |> Application.add_new_child(MishkaPay.Registry)
      |> Application.add_new_child(keys, after: [MishkaPay.Registry])
      |> webhook_plug()
      |> registry()
      |> test_helper()
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
      |> then(
        &if(options[:ash] or options[:admin], do: ash(&1, app_name, options[:admin]), else: &1)
      )
      |> then(&if(options[:pubsub], do: pubsub(&1), else: &1))
      |> Igniter.add_notice("""
      Mishka Pay is set up.

        * Give the keys: STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET (test keys outside production),
          or answer each site's own in #{inspect(keys)}.
        * Point Stripe's webhook to https://<your host>/pay/webhooks/stripe/<tenant>:
          mix mishka_pay.stripe.webhook_endpoint --url <it> makes a thin event destination with
          the events in MishkaPay.Providers.Stripe.thin_events/0.
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

    # Providers, keys and listeners are mishka_installer plugins, kept in its Mnesia registry: one
    # folder per environment (a test run never reads dev's) that git leaves out.
    defp registry(igniter) do
      dir = Sourceror.parse_string!(~S|Path.expand("../.mnesia/#{config_env()}", __DIR__)|)

      igniter
      |> Config.configure_new(
        "config.exs",
        :mishka_installer,
        [MishkaInstaller.MnesiaRepo, :mnesia_dir],
        {:code, dir}
      )
      |> Config.configure_new(
        "config.exs",
        :mishka_installer,
        [MishkaInstaller.MnesiaRepo, :essential],
        [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]
      )
      |> Igniter.create_or_update_file(".gitignore", "/.mnesia/\n", fn source ->
        content = Rewrite.Source.get(source, :content)

        case String.contains?(content, "/.mnesia/") do
          true ->
            source

          false ->
            Rewrite.Source.update(
              source,
              :content,
              String.trim_trailing(content) <> "\n\n/.mnesia/\n"
            )
        end
      end)
    end

    # A module the project already has stays as the project wrote it, so running again is safe.
    defp create_once(igniter, module, contents) do
      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        module,
        contents,
        &{:ok, &1}
      )
    end

    # Tests wait for the provider the application starts, and get `MishkaPay.Test.put_keys/3`.
    defp test_helper(igniter) do
      code = """
      MishkaPay.Test.setup!()
      MishkaPay.Test.await_plugin!(MishkaPay.Providers.Stripe)
      """

      igniter
      |> Igniter.include_existing_file("test/test_helper.exs", required?: false)
      |> Igniter.update_elixir_file("test/test_helper.exs", fn zipper ->
        with :error <- Function.move_to_function_call(zipper, {MishkaPay.Test, :setup!}, 0),
             {:ok, start} <- Function.move_to_function_call(zipper, {ExUnit, :start}, [0, 1]) do
          {:ok, Common.add_code(start, code, placement: :before)}
        else
          {:ok, _set_up} -> {:ok, zipper}
          :error -> {:ok, zipper}
        end
      end)
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

    # The listeners `MishkaPay.Ash.Resource` makes for a kind (`MishkaPay.Ash.Resource.Kinds.listeners/1`).
    defp listeners(:inbox), do: [MishkaPayListener, MishkaPayAnswerListener]
    defp listeners(_kind), do: [MishkaPayListener]

    defp ash(igniter, app_name, admin?) do
      resources = @resources ++ ((admin? && @admin_resources) || [])

      domain = Igniter.Project.Module.module_name(igniter, "Pay")
      repo = Igniter.Project.Module.module_name(igniter, "Repo")

      # Its DSL is written without parentheses: the formatter learns that before the resources.
      igniter = Igniter.Project.Formatter.import_dep(igniter, :mishka_pay)

      igniter =
        Enum.reduce(resources, create_once(igniter, domain, domain_body()), fn {name, kind, table},
                                                                               igniter ->
          resource = Module.concat(domain, name)

          igniter =
            igniter
            |> create_once(resource, resource_body(domain, kind, table, repo))
            |> add_resource(domain, resource)

          Enum.reduce(listeners(kind), igniter, fn listener, igniter ->
            Application.add_new_child(igniter, Module.concat(resource, listener),
              after: [MishkaPay.Registry]
            )
          end)
        end)

      igniter
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
      |> Config.configure_new("config.exs", :ash, [:default_string_length_count], :codepoints)
      |> Igniter.add_notice("""
      Mishka Pay's Ash layer is in #{inspect(domain)}: run `mix ash.codegen mishka_pay` and migrate.
      It needs ash_postgres and ash_oban (`mix igniter.install ash_postgres ash_oban`).
      """)
    end

    defp resource_body(domain, kind, table, repo) do
      """
      use Ash.Resource,
        domain: #{inspect(domain)},
        data_layer: AshPostgres.DataLayer,
        extensions: [MishkaPay.Ash.Resource]

      mishka_pay do
        kind #{inspect(kind)}
      end

      postgres do
        table "#{table}"
        repo #{inspect(repo)}
      end
      """
    end

    # The resource in the domain's `resources` block, unless it is there.
    defp add_resource(igniter, domain, resource) do
      Igniter.Project.Module.find_and_update_module!(igniter, domain, fn zipper ->
        with {:ok, zipper} <-
               Function.move_to_function_call_in_current_scope(zipper, :resources, 1),
             {:ok, zipper} <- Common.move_to_do_block(zipper),
             :error <-
               Function.move_to_function_call_in_current_scope(
                 zipper,
                 :resource,
                 [1, 2],
                 &Function.argument_equals?(&1, 0, resource)
               ) do
          {:ok, Common.add_code(zipper, "resource #{inspect(resource)}")}
        else
          _there -> {:ok, zipper}
        end
      end)
    end

    # The domain alone: each resource is added to its `resources` block after, so a run with
    # `--admin` on an installed project adds the new ones.
    defp domain_body do
      """
      use Ash.Domain

      resources do
      end
      """
    end

    defp pubsub(igniter) do
      broadcast = Igniter.Project.Module.module_name(igniter, "Pay.Broadcast")
      pubsub = Igniter.Project.Module.module_name(igniter, "PubSub")

      igniter
      |> create_once(broadcast, "use MishkaPay.PubSub, pubsub: #{inspect(pubsub)}")
      |> Application.add_new_child(broadcast, after: [Phoenix.PubSub])
    end
  end
end
