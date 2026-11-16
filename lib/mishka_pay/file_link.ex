# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.FileLink do
  @moduledoc """
  A public address of a `MishkaPay.File`, made with `MishkaPay.file_link/4`: anyone with `:url`
  can open the file without a key, so a site can show it to a person, until `:expires_at`. A
  guarded_struct the provider fills in.

    * `:id`: the provider's id of the link (`link_...` at Stripe); `:file_id`: the file it opens.
    * `:url`: the address to show.
    * `:expires_at`: when it stops working, or `nil` for never; `:expired`: whether it has.
    * `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :tenant, term()
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :file_id, String.t(), derives: "validate(string)"
    field :url, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :expires_at, DateTime.t(), derives: "validate(struct)"
    field :expired, boolean(), default: false, derives: "validate(boolean)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end
