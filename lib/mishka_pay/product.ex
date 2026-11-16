# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Product do
  @moduledoc """
  Something sold, as the provider keeps it in its catalog (`prod_...` at Stripe), with its prices
  (`MishkaPay.Price` with `:product_id`). A guarded_struct.

  Made with `MishkaPay.create_product/1`, changed with `MishkaPay.update_product/1`, taken off sale
  with `MishkaPay.archive_product/3`, read with `MishkaPay.fetch_product/3` and
  `MishkaPay.list_products/3`. A checkout sells a catalog price by its id (`items: [%{id:
  "price_..."}]`).

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:id`: optional, the product's own id (`"shop-ebook"`); the provider makes one when it is
      left out.
    * `:name`, `:description`: what the buyer sees.
    * `:tax_code`: the provider's tax category, such as Stripe's `"txcd_10302000"`.
    * `:active`: on sale (`true` by default); `false` keeps it for past sales only.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:default_price_id`, `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=200)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=250)"

    field :description, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=1000)"

    field :tax_code, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=100)"

    field :active, boolean(), derives: "validate(boolean)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
    field :default_price_id, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end
