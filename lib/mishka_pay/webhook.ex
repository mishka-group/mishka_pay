# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Webhook do
  @moduledoc """
  Receives provider webhooks. A project mounts it as a Plug, for example
  `forward "/pay/webhooks", MishkaPay.Webhook`. It reads the raw body, finds the provider from the
  path, lets the provider check the signature, and fires `mishka_pay:webhook:received`. It answers
  quickly and does no work of its own: whoever listens on the event does the work.

  Stage 3 adds it.
  """
end
