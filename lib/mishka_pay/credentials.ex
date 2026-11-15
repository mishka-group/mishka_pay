# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Credentials do
  @moduledoc """
  The keys of one provider for one site (secret key, webhook secret, test or live).

  Mishka Pay keeps no keys itself. It fires `mishka_pay:credentials` with the provider id and the
  site, and the host's plugin answers: from its settings, its database or the environment. A project
  with one site answers the same keys every time.

  Stage 1 adds the struct and the lookup.
  """
end
