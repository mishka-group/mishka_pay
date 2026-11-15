# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Test.SiteKeys do
  @moduledoc "A host's keys plugin with one key set per site, as a multi-site project writes it."

  use MishkaPay.Credentials, priority: 10

  @impl MishkaPay.Credentials
  def credentials("acme", "site-a"),
    do: %{
      secret_key: "  sk_test_site_a  ",
      webhook_secret: "whsec_site_a",
      extra: %{"account" => "acct_1"}
    }

  def credentials("acme", "site-unknown-mode"), do: %{secret_key: "sk_test_x", mode: :sandbox}
  def credentials("acme", "site-extra-key"), do: %{secret_key: "sk_test_x", token: "t"}
  def credentials("acme", "site-boom"), do: raise("the settings store is down")
  def credentials(_provider, _tenant), do: nil
end
