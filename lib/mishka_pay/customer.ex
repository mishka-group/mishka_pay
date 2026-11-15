# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Customer do
  @moduledoc """
  A buyer as a checkout names them: an email the provider fills in for them, or the provider's own
  id of a customer it already knows (`cus_...` at Stripe), one or the other. A guarded_struct.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :one_of} do
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :email, String.t(), derives: "sanitize(trim, downcase) validate(string, email_r)"
  end

  @doc false
  def one_of(%{id: id, email: email}) when is_binary(id) == is_binary(email),
    do:
      {:error,
       %{
         field: :customer,
         action: :customer,
         message: "A customer is an id or an email, one of them"
       }}

  def one_of(attrs), do: {:ok, attrs}
end
