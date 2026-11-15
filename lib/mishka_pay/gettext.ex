# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Gettext do
  @moduledoc """
  Default Gettext backend for Mishka Pay. It holds every message a person can see, such as the
  errors on a checkout form or a refund, in the `mishka_pay` domain.

  ## Using your own Gettext backend

      config :mishka_pay, :gettext_backend, MyAppWeb.Gettext

  Then copy `priv/gettext/mishka_pay.pot` and the `mishka_pay.po` files from Mishka Pay into your
  project's `priv/gettext` and translate them there, as for every Mishka library.
  """

  use Gettext.Backend, otp_app: :mishka_pay, priv: "priv/gettext"
end
