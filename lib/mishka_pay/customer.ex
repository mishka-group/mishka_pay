# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Customer do
  @moduledoc """
  A buyer as a checkout names them: an email the provider fills in for them, or the provider's own
  id of a customer it already knows (`cus_...` at Stripe). A guarded_struct.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :email, String.t(), derives: "sanitize(trim, downcase) validate(string, email_r)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, max_len=200)"
  end
end
