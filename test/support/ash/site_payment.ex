# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Support.SitePayment do
  @moduledoc """
  A multi-tenant host's payment resource, as Mishka CMS keeps its rows: Ash multitenancy on the
  host's own `:site_id`, with the `:payment` kind of `MishkaPay.Ash.Resource` on top.
  """

  use Ash.Resource,
    domain: MishkaPay.Support.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [MishkaPay.Ash.Resource]

  postgres do
    table "site_payments"
    repo MishkaPay.Support.Repo
  end

  mishka_pay do
    kind :payment
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
  end

  attributes do
    attribute :site_id, :string, allow_nil?: false, public?: true
  end
end
