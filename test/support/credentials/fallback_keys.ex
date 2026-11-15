# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.FallbackKeys do
  @moduledoc "A host's keys plugin after `MishkaPay.Support.SiteKeys` that answers every Acme tenant."

  use MishkaPay.Credentials, priority: 60

  @impl MishkaPay.Credentials
  def credentials("acme", _tenant), do: %{secret_key: "sk_test_fallback"}
  def credentials(_provider, _tenant), do: nil
end
