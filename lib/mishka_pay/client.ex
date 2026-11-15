# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Client do
  @moduledoc """
  The HTTP base every provider adapter builds on, over Req: a timeout, retries on
  network errors and 5xx answers, one idempotency key reused across the retries of a write, and a
  telemetry event for each request. An adapter adds its own URL, auth and version header.

  Stage 1 adds it.
  """
end
