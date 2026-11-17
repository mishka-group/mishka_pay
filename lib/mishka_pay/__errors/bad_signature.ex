# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Errors.BadSignature do
  @moduledoc """
  A webhook message that cannot be trusted, so nothing in it is used.

    * `:provider`: the provider's id.
    * `:reason`: `:missing` (no signature header), `:malformed` (a header or body that cannot be
      read), `:too_old` (signed outside the allowed time window, perhaps replayed), `:mismatch`
      (signed with another secret, or changed on the way), `:mode` (a live message checked with
      test keys, or the other way round), `:account` (about another account than the
      connected account the tenant acts for).
  """

  alias MishkaPay.Messages

  use Splode.Error, fields: [:provider, :reason], class: :invalid

  @impl true
  def message(%{provider: provider, reason: reason}),
    do: Messages.text(:bad_signature, provider: provider, reason: reason)
end
