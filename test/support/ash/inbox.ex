# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Inbox do
  @moduledoc "A host's inbox listener, as `MishkaPay.Ash.Inbox.Listener` shows it."

  use MishkaPay.Ash.Inbox.Listener, resource: MishkaPay.Support.WebhookEvent
end
