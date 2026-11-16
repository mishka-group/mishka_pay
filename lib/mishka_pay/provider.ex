# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Provider do
  @moduledoc """
  Every payment provider, Stripe included, implements these callbacks. A provider is one module:

      defmodule MyApp.Pay.Acme do
        use MishkaPay.Provider,
          id: "acme",
          label: "Acme Pay",
          capabilities: [:checkout, :refund, :webhook]
      end

  Supervise the module in the application that ships it, like any other mishka_installer plugin.
  `use` makes it a plugin on the `mishka_pay:providers` event (`MishkaPay.Events.providers/0`): it
  adds itself to the `providers` list the event carries. Supervising it installs the provider, and
  stopping its plugin in the installer takes it out. A project adds its own payment method the same
  way, without changing Mishka Pay.

  ## Options of `use`

    * `:id` (required): a short lowercase name, such as `"stripe"`. Every call names the provider by it.
    * `:label` (required): the name a person reads.
    * `:capabilities`: what the provider can do, from `t:capability/0`. A call to something not
      listed answers a `MishkaPay.Errors.Unsupported` error without reaching the provider.
    * `:priority`: the plugin's priority on the event, 50 by default. When two installed providers
      share an id, the one that comes first wins.

  ## Which providers are installed

  `all/0`, `offered/0` and `fetch/1` ask the event every time, so mishka_installer's own registry is
  the only list and nothing is cached. A module counts only when it implements every required
  callback. When a plugin of the event is registered but not loaded, the event cannot run and no
  provider can be told installed: `fetch/1` then answers a `MishkaPay.Errors.UnknownProvider` error
  with the reason `:cannot_run`.

  The same pattern as `MishkaCmsCore.ProviderRegistry` and `MishkaCmsCore.Captcha.Provider`.

  ## Operations

  Each capability brings the callbacks it needs, and a provider that declares a capability without
  them does not compile:

    * `:checkout`: `checkout/2`, `fetch_checkout/2` and `fetch_payment/2`;
    * `:refund`: `refund/2`;
    * `:webhook`: `verify_webhook/3`.

  Every operation takes a guarded_struct and the tenant's `MishkaPay.Credentials`, and answers a
  guarded_struct or a `MishkaPay.Errors` error. A project calls them through `MishkaPay`, which
  checks the capability, asks for the keys and emits telemetry first.
  """

  require Logger

  alias MishkaInstaller.Event.Hook
  alias MishkaPay.{Errors, Events}

  @capabilities [:checkout, :refund, :subscription, :webhook, :return_verify]

  @typedoc """
  What a provider can do:

    * `:checkout`: sends the buyer to pay, or embeds a payment form.
    * `:refund`: gives money back on a payment.
    * `:subscription`: charges again on a schedule.
    * `:webhook`: sends signed messages when something changes.
    * `:return_verify`: has no webhook; the buyer comes back to a return URL and the payment is
      checked with a call to the provider.
  """
  @type capability :: :checkout | :refund | :subscription | :webhook | :return_verify

  @doc "The provider's id, such as `\"stripe\"`. Set by `use`."
  @callback id() :: String.t()

  @doc "The name a person reads. Set by `use`."
  @callback label() :: String.t()

  @doc "What the provider can do. Set by `use`."
  @callback capabilities() :: [capability()]

  @doc "Optional. `false` keeps an installed provider out of `offered/0`, for example while it has no keys anywhere."
  @callback offered?() :: boolean()

  @doc """
  With `:checkout`. Opens a checkout at the provider with the tenant's keys and answers it with
  the provider's `:id`, `:url` and `:status` filled in.
  """
  @callback checkout(MishkaPay.Checkout.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Checkout.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:checkout`. Reads a checkout again by its id, as the buyer comes back to the success page:
  what the provider fills in (`:id`, `:url`, `:status`, `:payment_id`), with `:provider` and the
  caller's `:reference`. Its items and URLs stay empty.
  """
  @callback fetch_checkout(checkout_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Checkout.t()} | {:error, Splode.Error.t()}

  @doc "With `:checkout`. Reads one payment again from the provider, its source of truth."
  @callback fetch_payment(payment_id :: String.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Payment.t()} | {:error, Splode.Error.t()}

  @doc "With `:refund`. Gives money back on a payment and answers the refund as the provider made it."
  @callback refund(MishkaPay.Refund.t(), MishkaPay.Credentials.t()) ::
              {:ok, MishkaPay.Refund.t()} | {:error, Splode.Error.t()}

  @doc """
  With `:webhook`. Checks a provider's signed message (the raw body and headers as they came) with
  the tenant's webhook secret and answers it as a `MishkaPay.Event`, or a
  `MishkaPay.Errors.BadSignature` error.
  """
  @callback verify_webhook(
              payload :: binary(),
              headers :: [{String.t(), String.t()}],
              MishkaPay.Credentials.t()
            ) ::
              {:ok, MishkaPay.Event.t()} | {:error, Splode.Error.t()}

  @optional_callbacks offered?: 0,
                      checkout: 2,
                      fetch_checkout: 2,
                      fetch_payment: 2,
                      refund: 2,
                      verify_webhook: 3

  @operations %{
    checkout: [checkout: 2, fetch_checkout: 2, fetch_payment: 2],
    refund: [refund: 2],
    webhook: [verify_webhook: 3]
  }

  @options [:id, :label, :capabilities, :priority]

  @doc false
  defmacro __using__(opts) do
    check_options!(opts)
    id = Keyword.fetch!(opts, :id)
    label = Keyword.fetch!(opts, :label)
    capabilities = Keyword.get(opts, :capabilities, [])
    priority = Keyword.get(opts, :priority, 50)

    check_id!(id)
    check_label!(label)
    check_capabilities!(capabilities)
    check_priority!(priority)

    quote do
      use MishkaInstaller.Event.Hook,
        event: unquote(Events.providers()),
        initial: %{priority: unquote(priority)}

      @behaviour MishkaPay.Provider
      @before_compile MishkaPay.Provider
      @mishka_pay_capabilities unquote(capabilities)

      @impl true
      def call(%{providers: providers} = state) when is_list(providers),
        do: {:reply, %{state | providers: providers ++ [__MODULE__]}}

      def call(state), do: {:reply, state}

      @impl MishkaPay.Provider
      def id, do: unquote(id)

      @impl MishkaPay.Provider
      def label, do: unquote(label)

      @impl MishkaPay.Provider
      def capabilities, do: unquote(capabilities)
    end
  end

  # A capability is a promise: a provider that declares one and lacks its functions does not
  # compile, so it can never be offered and then fail at the first payment.
  @doc false
  defmacro __before_compile__(env) do
    missing =
      for capability <- Module.get_attribute(env.module, :mishka_pay_capabilities),
          {name, arity} <- Map.get(@operations, capability, []),
          not Module.defines?(env.module, {name, arity}, :def),
          do: "#{name}/#{arity} (for #{inspect(capability)})"

    case missing do
      [] ->
        :ok

      _missing ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{inspect(env.module)} declares capabilities without " <> Enum.join(missing, ", ")
    end

    nil
  end

  @doc "Lists what a capability asks a provider to define, such as `[checkout: 2, fetch_payment: 2]`."
  @spec operations(capability()) :: keyword(pos_integer())
  def operations(capability), do: Map.get(@operations, capability, [])

  @doc """
  The offered provider `id` when it has `capability`, or an `UnknownProvider` or `Unsupported`
  error.
  """
  @spec capable(String.t(), capability()) :: {:ok, module()} | {:error, Splode.Error.t()}
  def capable(id, capability) do
    with {:ok, provider} <- fetch(id) do
      case capability in provider.capabilities() do
        true -> {:ok, provider}
        false -> {:error, Errors.Unsupported.exception(provider: id, operation: capability)}
      end
    end
  end

  @doc "Every installed provider, the first of each id. None when the event cannot run."
  @spec all() :: [module()]
  def all do
    case installed() do
      {:ok, providers} -> providers
      {:error, :cannot_run} -> []
    end
  end

  @doc "The installed providers this installation offers: every one, unless its `offered?/0` says not."
  @spec offered() :: [module()]
  def offered, do: offered_of(all())

  @doc "The offered provider whose id is `id`."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, Splode.Error.t()}
  def fetch(id) when is_binary(id) do
    case installed() do
      {:ok, providers} -> providers |> offered_of() |> Enum.find(&(&1.id() == id)) |> found(id)
      {:error, :cannot_run} -> unknown(id, :cannot_run)
    end
  end

  defp found(nil, id), do: unknown(id, :not_installed)
  defp found(provider, _id), do: {:ok, provider}

  defp unknown(id, reason),
    do: {:error, Errors.UnknownProvider.exception(provider: id, reason: reason)}

  defp installed do
    case Hook.call(Events.providers(), %{providers: []}, cannot_run: :cannot_run) do
      %{providers: providers} when is_list(providers) ->
        {:ok, providers |> Enum.filter(&provider?/1) |> Enum.uniq_by(& &1.id())}

      :cannot_run ->
        {:error, :cannot_run}

      _not_an_answer ->
        {:ok, []}
    end
  end

  # Every required callback, not one picked as a sample: a module missing one would be offered and
  # then fail when that one is called.
  defp provider?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and __MODULE__ in behaviours(module) and
      Enum.all?(
        __MODULE__.behaviour_info(:callbacks) -- __MODULE__.behaviour_info(:optional_callbacks),
        fn {name, arity} -> function_exported?(module, name, arity) end
      )
  end

  defp provider?(_other), do: false

  defp offered_of(providers), do: Enum.filter(providers, &offered?/1)

  # One provider whose `offered?/0` raises is left out, and the others are still offered.
  defp offered?(provider) do
    not function_exported?(provider, :offered?, 0) or provider.offered?() == true
  rescue
    exception ->
      Logger.warning(
        "mishka_pay: #{inspect(provider)}.offered?/0 raised and is not offered: " <>
          Exception.message(exception)
      )

      false
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

  defp check_options!(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown MishkaPay.Provider options: #{inspect(unknown)}"
    end
  end

  defp check_id!(id) when is_binary(id) do
    case Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, id) do
      true ->
        :ok

      false ->
        raise ArgumentError,
              "a provider id is lowercase letters, digits and _, got: #{inspect(id)}"
    end
  end

  defp check_id!(_id),
    do: raise(ArgumentError, "a provider id is a literal string, such as \"acme\"")

  defp check_label!(label) when is_binary(label) and label != "", do: :ok
  defp check_label!(_label), do: raise(ArgumentError, "a provider label is a literal string")

  defp check_capabilities!(capabilities) when is_list(capabilities) do
    case {Enum.reject(capabilities, &(&1 in @capabilities)),
          capabilities -- Enum.uniq(capabilities)} do
      {[], []} ->
        :ok

      {[], twice} ->
        raise ArgumentError, "provider capabilities listed twice: #{inspect(twice)}"

      {unknown, _twice} ->
        raise ArgumentError, "unknown provider capabilities: #{inspect(unknown)}"
    end
  end

  defp check_capabilities!(_other),
    do: raise(ArgumentError, "provider capabilities is a literal list of atoms")

  defp check_priority!(priority) when is_integer(priority) and priority >= 0, do: :ok

  defp check_priority!(_other),
    do: raise(ArgumentError, "a provider priority is a whole number, 0 or more")
end
