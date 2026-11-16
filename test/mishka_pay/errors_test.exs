# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.ErrorsTest do
  use ExUnit.Case, async: true

  alias MishkaPay.Errors

  # The shape `builder/1` of a guarded_struct gives for a missing field.
  defp builder_error do
    GuardedStruct.Errors.from_tuple(
      {:error, [%{field: :amount, action: :required, message: "amount is required"}]}
    )
  end

  defp declined, do: Errors.Declined.exception(provider: "stripe", reason: "card_declined")

  defp unsupported, do: Errors.Unsupported.exception(provider: "acme", operation: :refund)

  test "a guarded_struct error joins Mishka Pay's own errors in the invalid class" do
    assert %Errors.Invalid{errors: errors} = Errors.to_class([declined(), builder_error()])

    assert MapSet.new([Errors.Declined, GuardedStruct.Errors.Validation]) ==
             MapSet.new(errors, & &1.__struct__)
  end

  test "errors a provider gives are in the provider class" do
    assert %Errors.Provider{errors: [_declined, _unsupported]} =
             Errors.to_class([declined(), unsupported()])
  end

  test "anything else is an unknown error that keeps what was given" do
    assert %Errors.Unknown{errors: [%Errors.UnknownError{error: "boom"}]} =
             Errors.to_class("boom")
  end

  test "messages name the provider and its reason" do
    assert Exception.message(declined()) == "stripe declined the payment: card_declined"
    assert Exception.message(unsupported()) == "Acme cannot do refund"
  end
end
