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

  The answer may use atom or string keys, and the mode may be `"test"` or `"live"`. Its own
  `:provider` and `:tenant` are ignored: they always come from the call.

  `inspect/1` shows only the provider, the tenant and the mode, so a key never reaches a log line.
  """

  use GuardedStruct

  require Logger

  alias MishkaInstaller.Event.Hook
  alias MishkaPay.{Errors, Events}

  @derive {Inspect, only: [:provider, :tenant, :mode]}

  @timeout Application.compile_env(:mishka_pay, :credentials_timeout, 5_000)

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
    field :webhook_secret, String.t(), derives: "sanitize(trim) validate(string)"
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
  """
  @spec fetch(String.t(), term(), keyword()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def fetch(provider, tenant \\ nil, opts \\ []) when is_binary(provider) do
    timeout = opts |> Keyword.get(:timeout, @timeout) |> timeout!()

    task =
      Task.Supervisor.async_nolink(MishkaPay.TaskSupervisor, fn ->
        Hook.call(Events.credentials(), %{provider: provider, tenant: tenant, credentials: nil},
          cannot_run: :cannot_run,
          raised: :raised
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> answer(answer, provider, tenant)
      {:exit, reason} -> exited(provider, tenant, reason)
      nil -> missing(provider, tenant, :timeout)
    end
  end

  defp timeout!(:infinity), do: :infinity
  defp timeout!(ms) when is_integer(ms) and ms >= 0, do: ms

  defp timeout!(other),
    do:
      raise(
        ArgumentError,
        "timeout is milliseconds (0 or more) or :infinity, got: #{inspect(other)}"
      )

  defp exited(provider, tenant, reason) do
    Logger.warning(
      "mishka_pay: a #{provider} keys plugin for tenant #{inspect(tenant)} exited: " <>
        Exception.format_exit(reason)
    )

    missing(provider, tenant, :exited)
  end

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

  defp answer(reason, provider, tenant) when reason in [:cannot_run, :raised],
    do: missing(provider, tenant, reason)

  defp answer(%{credentials: _not_a_map}, _provider, _tenant) do
    Errors.from_builder(
      {:error,
       [
         %{
           field: :credentials,
           action: :answer,
           message: "A keys plugin must answer a map or nil"
         }
       ]}
    )
  end

  # A plugin that reads its keys from JSON or settings answers the mode as a string.
  @doc false
  def mode(:mode, mode) when mode in ["test", "live"],
    do: {:ok, :mode, String.to_existing_atom(mode)}

  def mode(:mode, mode), do: {:ok, :mode, mode}

  defp missing(provider, tenant, reason),
    do:
      {:error,
       Errors.MissingCredentials.exception(provider: provider, tenant: tenant, reason: reason)}
end
