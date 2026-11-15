# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.MessagesTest do
  # Switches the :gettext_backend config every test reads.
  use ExUnit.Case, async: false

  alias MishkaPay.{Errors, Messages, Money}

  doctest MishkaPay.Messages

  test "messages come in English from Mishka Pay's own backend" do
    assert Messages.gettext_backend() == MishkaPay.Gettext

    assert {:error, %Errors.Invalid{errors: [%{message: "The amount field is too large"}]}} =
             Money.new("1e40", "USD")
  end

  test "a host's backend translates field errors and error messages in the caller's locale" do
    Application.put_env(:mishka_pay, :gettext_backend, MishkaPay.Support.Gettext)
    on_exit(fn -> Application.delete_env(:mishka_pay, :gettext_backend) end)

    Gettext.with_locale(MishkaPay.Support.Gettext, "de", fn ->
      assert {:error, %Errors.Invalid{errors: [%{message: "Der Betrag ist zu groß"}]}} =
               Money.new("1e40", "USD")

      declined = Errors.Declined.exception(provider: "stripe", reason: "card_declined")
      assert Exception.message(declined) == "stripe hat die Zahlung abgelehnt: card_declined"
    end)
  end

  test "a message without a translation falls back to English" do
    Application.put_env(:mishka_pay, :gettext_backend, MishkaPay.Support.Gettext)
    on_exit(fn -> Application.delete_env(:mishka_pay, :gettext_backend) end)

    Gettext.with_locale(MishkaPay.Support.Gettext, "de", fn ->
      assert Messages.text(:amount_negative) == "The amount field must be zero or more"
    end)
  end
end
