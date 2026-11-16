# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.File do
  @moduledoc """
  A file the provider keeps (`file_...` at Stripe), uploaded with `MishkaPay.upload_file/1` or read
  with `MishkaPay.fetch_file/3`. Put its `:id` in a dispute's evidence to send it to the bank. A
  guarded_struct the provider fills in.

    * `:id`: the provider's id of the file.
    * `:purpose`: `:dispute_evidence`, or `:other` for a file kept for something else.
    * `:filename`, `:size` (in bytes), `:type` (the provider's word for its format, such as
      `"pdf"` or `"png"`).
    * `:url`: where the provider serves its bytes, when it does. At Stripe this address needs the
      secret key; `MishkaPay.file_link/4` makes one a page can show.
    * `:expires_at`: when the provider deletes it (Stripe keeps dispute evidence for 9 months).
    * `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :tenant, term()
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :purpose, atom(), derives: "validate(enum=Atom[dispute_evidence::other])"
    field :filename, String.t(), derives: "validate(string)"
    field :size, non_neg_integer(), derives: "validate(integer)"
    field :type, String.t(), derives: "validate(string)"
    field :url, String.t(), derives: "validate(string)"
    field :expires_at, DateTime.t(), derives: "validate(struct)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end
