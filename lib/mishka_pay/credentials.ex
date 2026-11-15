# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Credentials do
  @moduledoc """
  The keys of one provider for one tenant (a site, a shop, an account): the secret key, the
  publishable key, the webhook secret, test or live, and whatever else the provider needs in
  `:extra`.

  Mishka Pay keeps no keys itself. `fetch/2` fires `mishka_pay:credentials`
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

  `inspect/1` shows only the provider, the tenant and the mode, so a key never reaches a log line.
  """

  use GuardedStruct

  alias MishkaInstaller.Event.Hook
  alias MishkaPay.{Errors, Events}
  alias MishkaPay.Helpers.Required

  @derive {Inspect, only: [:provider, :tenant, :mode]}

  guardedstruct authorized_fields: true do
    field(:provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(string, not_empty)",
      validator: {Required, :call}
    )

    field(:tenant, term())

    field(:mode, :test | :live,
      default: :test,
      derives: "validate(enum=Atom[test::live])",
      validator: {Required, :call}
    )

    field(:secret_key, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(string, not_empty)",
      validator: {Required, :call}
    )

    field(:publishable_key, String.t(), derives: "sanitize(trim) validate(string)")
    field(:webhook_secret, String.t(), derives: "sanitize(trim) validate(string)")
    dynamic_field(:extra)
  end

  @doc """
  The keys of `provider` for `tenant`, as a host plugin answers them: a map of this struct's fields
  (without `:provider` and `:tenant`, which come from the call), or `nil` when it has none.
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
  plugin answers, the event cannot run or a plugin raises. An answer that is not valid keys is an
  `:invalid` class error naming the field.
  """
  @spec fetch(String.t(), term()) :: {:ok, t()} | {:error, Splode.Error.t()}
  def fetch(provider, tenant \\ nil) when is_binary(provider) do
    Events.credentials()
    |> Hook.call(%{provider: provider, tenant: tenant, credentials: nil},
      cannot_run: :cannot_run,
      raised: :raised
    )
    |> answer(provider, tenant)
  end

  defp answer(%{credentials: %{} = keys}, provider, tenant),
    do:
      keys
      |> Map.merge(%{provider: provider, tenant: tenant})
      |> builder()
      |> Errors.from_builder()

  defp answer(%{credentials: nil}, provider, tenant), do: missing(provider, tenant, :no_answer)

  defp answer(reason, provider, tenant) when reason in [:cannot_run, :raised],
    do: missing(provider, tenant, reason)

  defp missing(provider, tenant, reason),
    do:
      {:error,
       Errors.MissingCredentials.exception(provider: provider, tenant: tenant, reason: reason)}
end
