# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Rejection.Listener do
    @moduledoc """
    Makes a module the `mishka_pay:webhook:answered` listener that counts the webhook messages
    `MishkaPay.Webhook` refused in a resource of the `:webhook_rejection` kind
    (`MishkaPay.Ash.Resource`), one row per provider, site, reason and day:

        defmodule MyApp.Pay.Rejections do
          use MishkaPay.Ash.Rejection.Listener, resource: MyApp.Pay.WebhookRejection
        end

    `MishkaPay.Ash.Resource` makes one for each such resource, as `<Resource>.MishkaPayListener`.
    A message is counted when it was refused (a 4xx answer and no checked event) for a provider
    that is installed with webhooks: a bad or old signature, a site without keys (`:tenant` nil),
    an unreadable or too large body. Its body is never kept. The count goes up in the same
    statement that finds the day's row, so two messages at once both count.
    """

    @doc false
    defmacro __using__(opts) do
      resource = Keyword.fetch!(opts, :resource)
      priority = Keyword.get(opts, :priority, 50)

      quote do
        use MishkaInstaller.Event.Hook,
          event: unquote(MishkaPay.Events.webhook_answered()),
          initial: %{priority: unquote(priority)}

        @impl true
        def call(%{event: nil, provider: provider, status: status} = state)
            when is_binary(provider) and status in 400..499,
            do: {:reply, MishkaPay.Ash.Rejection.Listener.count(unquote(resource), state)}

        def call(state), do: {:reply, state}
      end
    end

    @doc false
    def count(resource, state) do
      now = DateTime.utc_now()

      attrs = %{
        provider: state.provider,
        tenant: state.tenant && to_string(state.tenant),
        reason: to_string(state.outcome),
        day: DateTime.to_date(now),
        last_at: now
      }

      _result = Ash.create(resource, attrs, action: :count, authorize?: false)
      state
    end
  end
end
