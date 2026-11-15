# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.MissingCredentials do
  @moduledoc """
  No keys for this provider and tenant.

    * `:provider`, `:tenant`: what was asked for.
    * `:reason`: `:no_answer` when no plugin on `mishka_pay:credentials` answered, `:cannot_run` when
      a plugin of the event is registered but not loaded, `:raised` when one raised.
  """

  use Splode.Error, fields: [:provider, :tenant, :reason], class: :invalid

  @impl true
  def message(%{provider: provider, tenant: tenant, reason: :no_answer}),
    do: "no #{provider} keys for tenant #{inspect(tenant)}"

  def message(%{provider: provider, tenant: tenant, reason: reason}),
    do: "the #{provider} keys for tenant #{inspect(tenant)} cannot be read (#{reason})"
end
