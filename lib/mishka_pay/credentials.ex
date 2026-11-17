# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Credentials do
  @moduledoc """
  The keys of one provider for one tenant (a site, a shop, an account): the secret key, the
  publishable key, the webhook secret, test or live, and whatever else the provider needs in
  `:extra`.

  Mishka Pay keeps no keys itself. `fetch/3` fires `mishka_pay:credentials`
  (`MishkaPay.Events.credentials/0`) and the host answers through a plugin, from its settings, its
  database or the environment:

      defmodule MyApp.PayKeys do
        use MishkaPay.Credentials

        @impl MishkaPay.Credentials
        def credentials("stripe", _tenant),
          do: %{secret_key: System.fetch_env!("STRIPE_SECRET_KEY"), mode: :live}

        def credentials(_provider, _tenant), do: nil
      end

  Supervise it like any other plugin. A project with one site answers the same keys for every
  tenant; a multi-site one reads the tenant's own. When several plugins listen, the first one that
  answers wins, in the order of their `:priority` (50 by default).

  Besides keys, the answer carries the provider's settings for the tenant:

    * `:merchant_of_record`: `true` or `false` turns selling as the merchant of record on or off
      for every checkout of this tenant (Stripe Managed Payments); left out, the provider
      account's own default applies. A checkout's own `:merchant_of_record` still wins.
    * `:automatic_tax`: `true` has the provider count the tax of this tenant's checkouts and
      payment links from the buyer's address (Stripe Tax); a checkout's own `:automatic_tax` still
      wins.
    * `:webhook_secrets`: other webhook secrets still accepted beside `:webhook_secret`, while a
      rolled secret runs out. Stripe keeps signing with the old secret for a while after a roll
      (up to a day), so a site lists the old one here and puts the new one in
      `:webhook_secret`; a message passes when any of them verifies it. Drop the old one once
      Stripe stops using it. Only for providers that check a shared secret (Stripe); PayPal checks
      its messages by `:webhook_secret`, the webhook id, alone.
    * `:refunds`: how this tenant refunds a payment. `:once` (the default): one refund, whole or
      in part, and a buyer who wants it again makes a new purchase. `:many`: part refunds until
      the payment is used up, as the provider itself allows; each refund then needs its own
      `:reference` (`MishkaPay.Refund`).
    * `:account_id`: the connected account this tenant acts for, at a provider with connected
      accounts (Stripe Connect, `acct_...`). A platform answers its own secret key with each site's
      connected account: every request is then made as that account (Stripe's `Stripe-Account`
      header), and a webhook message about any other account is refused. Left out, the tenant is
      the account that owns the secret key (the platform itself, or a plain site). It comes only
      from these keys: no call, request option or raw request can set the header. A provider
      without connected accounts (PayPal) never reads it.

  These are read at runtime on every call, never from `config.exs`, so each tenant of a
  multi-site project carries its own and a change in its settings applies to the next call.

  The answer may use atom or string keys, and the mode may be `"test"` or `"live"`. Its own
  `:provider` and `:tenant` are ignored: they always come from the call.

  `inspect/1` shows only the provider, the tenant and the mode, so a key never reaches a log line.
  """

  use GuardedStruct

  alias MishkaPay.{Errors, Events}
  alias MishkaPay.Helpers.Plugins

  @derive {Inspect, only: [:provider, :tenant, :mode]}

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :mode, :test | :live,
      default: :test,
      derives: "validate(not_nil_value, enum=Atom[test::live])",
      validator: {__MODULE__, :mode}

    field :secret_key, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :publishable_key, String.t(), derives: "sanitize(trim) validate(string)"
    field :merchant_of_record, boolean(), derives: "validate(boolean)"
    field :automatic_tax, boolean(), derives: "validate(boolean)"

    field :refunds, :once | :many,
      default: :once,
      derives: "validate(not_nil_value, enum=Atom[once::many])",
      validator: {__MODULE__, :refunds}

    field :account_id, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=255)",
      validator: {__MODULE__, :account_id}

    field :webhook_secret, String.t(), derives: "sanitize(trim) validate(string)"

    field :webhook_secrets, [String.t()],
      default: [],
      derives: "validate(list)",
      validator: {__MODULE__, :secret_list}

    dynamic_field :extra
  end

  @doc """
  Answers with a map of this struct's fields for `provider` and `tenant` (without `:provider` and
  `:tenant`, which come from the call), or `nil` when this plugin has no keys for them.
  """
  @callback credentials(provider :: String.t(), tenant :: term()) :: map() | nil

  @doc false
  defmacro __using__(opts) do
    priority = Keyword.get(opts, :priority, 50)

    quote do
      use MishkaInstaller.Event.Hook,
        event: unquote(Events.credentials()),
        initial: %{priority: unquote(priority)}

      @behaviour MishkaPay.Credentials

      @impl true
      def call(%{credentials: nil, provider: provider, tenant: tenant} = state),
        do: {:reply, %{state | credentials: credentials(provider, tenant)}}

      def call(state), do: {:reply, state}
    end
  end

  @doc """
  The keys of `provider` for `tenant`, or a `MishkaPay.Errors.MissingCredentials` error when no
  plugin answers, the event cannot run, a plugin raises, exits or throws, or no answer comes within
  the time limit. An answer that is not valid keys is an `:invalid` class error naming the field.

  The plugins run in a task under `MishkaPay.TaskSupervisor`, not linked to the caller, so a
  plugin that fails or hangs never takes the caller down. The limit is `opts[:timeout]`, or
  `config :mishka_pay, credentials_timeout: ms`, 5 seconds by default; `0` gives no plugin time to
  answer, and anything other than milliseconds or `:infinity` raises an `ArgumentError`.

  Each fetch is a telemetry span, `[:mishka_pay, :credentials, :start | :stop]`, with `:provider`
  and `:tenant`, and on `:stop` the `:outcome`: `:ok`, `:invalid`, or the missing-keys reason
  (`:no_answer`, `:cannot_run`, `:raised`, `:exited`, `:timeout`). Never a key.
  """
  @spec fetch(String.t(), term(), keyword()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def fetch(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    timeout =
      opts
      |> Keyword.get_lazy(:timeout, fn ->
        Application.get_env(:mishka_pay, :credentials_timeout, 5_000)
      end)
      |> timeout!()

    meta = %{provider: provider, tenant: tenant}

    :telemetry.span([:mishka_pay, :credentials], meta, fn ->
      result = ask(provider, tenant, timeout)
      {result, Map.put(meta, :outcome, outcome(result))}
    end)
  end

  # A test's own keys (`MishkaPay.Test.put_keys/3`) answer before the project's plugins.
  defp ask(provider, tenant, timeout) do
    case MishkaPay.Test.Keys.credentials(provider, tenant) do
      nil -> ask_plugins(provider, tenant, timeout)
      keys -> answer(%{credentials: keys}, provider, tenant)
    end
  end

  defp ask_plugins(provider, tenant, timeout) do
    state = %{provider: provider, tenant: tenant, credentials: nil}

    case Plugins.call(Events.credentials(), state, timeout) do
      {:ok, answer} -> answer(answer, provider, tenant)
      {:error, reason} -> missing(provider, tenant, reason)
    end
  end

  defp outcome({:ok, _keys}), do: :ok
  defp outcome({:error, %Errors.MissingCredentials{reason: reason}}), do: reason
  defp outcome({:error, _invalid}), do: :invalid

  defp timeout!(:infinity), do: :infinity
  defp timeout!(ms) when is_integer(ms) and ms >= 0, do: ms

  defp timeout!(other),
    do:
      raise(
        ArgumentError,
        "timeout is milliseconds (0 or more) or :infinity, got: #{inspect(other)}"
      )

  # `:provider` and `:tenant` come from the call, whichever key form the answer used, and an
  # `extra` given as nil takes its default.
  defp answer(%{credentials: %{} = keys}, provider, tenant) do
    keys
    |> Map.drop([:provider, :tenant, "provider", "tenant"])
    |> Map.reject(fn {key, value} -> key in [:extra, "extra"] and is_nil(value) end)
    |> Map.merge(%{provider: provider, tenant: tenant})
    |> builder()
    |> Errors.from_builder()
  end

  defp answer(%{credentials: nil}, provider, tenant), do: missing(provider, tenant, :no_answer)

  defp answer(%{credentials: _not_a_map}, _provider, _tenant) do
    Errors.from_builder(
      {:error,
       [
         %{
           field: :credentials,
           action: :answer,
           message: MishkaPay.Messages.text(:keys_answer)
         }
       ]}
    )
  end

  @doc """
  Every webhook secret `keys` accept: `:webhook_secret` first, then `:webhook_secrets`, each once,
  without empty ones. `[]` when the keys have none.
  """
  @spec webhook_secrets(t()) :: [String.t()]
  def webhook_secrets(%__MODULE__{webhook_secret: secret, webhook_secrets: secrets}),
    do: [secret | secrets] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

  @doc false
  def secret_list(field, nil), do: {:ok, field, []}

  def secret_list(field, secrets) when is_list(secrets) do
    trimmed = Enum.map(secrets, &(is_binary(&1) && String.trim(&1)))

    case Enum.all?(trimmed, &(is_binary(&1) and &1 != "")) do
      true -> {:ok, field, trimmed}
      false -> {:error, field, MishkaPay.Messages.text(:webhook_secrets)}
    end
  end

  def secret_list(field, _other), do: {:error, field, MishkaPay.Messages.text(:webhook_secrets)}

  # An account id goes into a request header: letters, digits and underscores only, so it can never
  # end the header or add another.
  @doc false
  def account_id(field, id) when is_binary(id) do
    trimmed = String.trim(id)

    case Regex.match?(~r/\A[A-Za-z0-9_]+\z/, trimmed) do
      true -> {:ok, field, trimmed}
      false -> {:error, field, MishkaPay.Messages.text(:account_id_plain)}
    end
  end

  def account_id(field, id), do: {:ok, field, id}

  # A plugin that reads its keys from JSON or settings answers the mode as a string.
  @doc false
  def mode(:mode, mode) when mode in ["test", "live"],
    do: {:ok, :mode, String.to_existing_atom(mode)}

  def mode(:mode, mode), do: {:ok, :mode, mode}

  @doc false
  def refunds(:refunds, refunds) when refunds in ["once", "many"],
    do: {:ok, :refunds, String.to_existing_atom(refunds)}

  def refunds(:refunds, refunds), do: {:ok, :refunds, refunds}

  defp missing(provider, tenant, reason),
    do:
      {:error,
       Errors.MissingCredentials.exception(provider: provider, tenant: tenant, reason: reason)}
end
