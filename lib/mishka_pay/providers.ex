# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Providers do
  @moduledoc """
  Which providers are installed: `all/0`, `offered/0` and `fetch/1` ask the
  `mishka_pay:providers` event every time, so the installer's own registry is the only list. The same
  pattern as `MishkaCmsCore.ProviderRegistry`.

  Stage 1 adds the functions.
  """
end
