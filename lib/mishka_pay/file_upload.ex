# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.FileUpload do
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
