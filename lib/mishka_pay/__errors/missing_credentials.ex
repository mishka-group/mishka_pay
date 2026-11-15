# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.MissingCredentials do
  @moduledoc """
  No keys for this provider and tenant.

    * `:provider`, `:tenant`: what was asked for.
    * `:reason`: `:no_answer` when no plugin on `mishka_pay:credentials` answered, `:cannot_run` when
      a plugin of the event is registered but not loaded, `:raised` when one raised, `:exited`
      when one called `exit` or `throw` (or a process it called died), `:timeout` when no answer
      came in time.
  """

  alias MishkaPay.Messages

  use Splode.Error, fields: [:provider, :tenant, :reason], class: :invalid

  @impl true
  def message(%{provider: provider, tenant: tenant, reason: :no_answer}),
    do: Messages.text(:missing_keys, provider: provider, tenant: inspect(tenant))

  def message(%{provider: provider, tenant: tenant, reason: reason}),
    do:
      Messages.text(:missing_keys_reason,
        provider: provider,
        tenant: inspect(tenant),
        reason: reason
      )
end
