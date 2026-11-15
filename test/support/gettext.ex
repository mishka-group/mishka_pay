# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.Gettext do
  @moduledoc "A host's own Gettext backend, with a German `mishka_pay` domain for the tests."

  use Gettext.Backend, otp_app: :mishka_pay, priv: "test/support/gettext"
end
