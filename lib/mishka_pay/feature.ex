# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Feature do
  @moduledoc """
  Something a customer may be entitled to use, such as `"seats"` or `"api-access"` (`feat_...` at
  Stripe). A guarded_struct.

  Made with `MishkaPay.create_feature/1` and attached to a catalog product with
  `MishkaPay.attach_feature/4`. A customer who buys the product gets a `MishkaPay.Entitlement` to
  it, which `MishkaPay.list_entitlements/4` reads.

  What the caller gives:

    * `:provider`, `:tenant`: which provider, with whose keys.
    * `:name`: its name, for the seller only.
    * `:lookup_key`: the host's own key for it, which the code checks access by.
    * `:metadata`: extra pairs, string keys to string values.

  What the provider fills in: `:id` and `:active`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
    field :tenant, term()
    field :id, String.t(), derives: "validate(string)"
    field :name, String.t(), derives: "sanitize(trim) validate(string, not_empty, max_len=80)"

    field :lookup_key, String.t(),
      derives: "sanitize(trim) validate(string, not_empty, max_len=80)"

    field :active, boolean(), derives: "validate(boolean)"
    dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}
  end
end
