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

defmodule MishkaPay.File.Link do
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

defmodule MishkaPay.File.Upload do
  @moduledoc """
  A file to upload to the provider with `MishkaPay.upload_file/1`, such as a receipt, a download
  log or a screenshot that answers a dispute. The provider keeps it and answers a
  `MishkaPay.File`; its `:id` then goes in the dispute's evidence (`MishkaPay.update_dispute/1`).
  A guarded_struct.

    * `:provider`, `:tenant`: as for a checkout.
    * `:purpose`: what the file is for. `:dispute_evidence`, evidence for a dispute.
    * `:filename`: the file's name, such as `"receipt.pdf"`; a plain name with no folder.
    * `:content_type`: its MIME type, such as `"application/pdf"`, `"image/jpeg"` or
      `"image/png"`.
    * `:content`: the file's bytes. Read the file first (`File.read/1`); Mishka Pay never reads a
      path.

  Each provider takes its own types and sizes, and refuses others before any request: Stripe
  takes dispute evidence as PDF, JPEG or PNG, up to 5 MB. `inspect/1` leaves out `:content`.
  """

  use GuardedStruct

  alias MishkaPay.Messages

  @derive {Inspect, except: [:content]}

  guardedstruct authorized_fields: true do
    field :provider, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

    field :tenant, term()

    field :purpose, :dispute_evidence,
      enforce: true,
      derives: "validate(not_nil_value, enum=Atom[dispute_evidence])",
      validator: {__MODULE__, :purpose}

    field :filename, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=255)",
      validator: {__MODULE__, :filename}

    field :content_type, String.t(),
      enforce: true,
      derives: "sanitize(trim, downcase) validate(not_nil_value, string, not_empty, max_len=255)"

    field :content, binary(), enforce: true, validator: {__MODULE__, :content}
  end

  @doc false
  def purpose(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(dispute_evidence)a)

  # A name only: no folder, no control character, so it can never point anywhere.
  @doc false
  def filename(field, name) when is_binary(name) do
    case Regex.match?(~r{[/\\\x00-\x1f\x7f]}, name) do
      true -> {:error, field, Messages.text(:filename_plain)}
      false -> {:ok, field, name}
    end
  end

  def filename(field, name), do: {:ok, field, name}

  @doc false
  def content(field, bytes) when is_binary(bytes) and byte_size(bytes) > 0,
    do: {:ok, field, bytes}

  def content(field, _empty), do: {:error, field, Messages.text(:file_empty)}
end
