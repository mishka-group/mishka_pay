# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Balance do
  @moduledoc """
  The money a provider holds for the seller, read with `MishkaPay.fetch_balance/2`. A
  guarded_struct the provider fills in.

    * `:provider`: whose balance.
    * `:available`: one `Money` per currency, ready to pay out.
    * `:pending`: one `Money` per currency, not available yet.

  A balance may be below zero, such as after refunds or disputes larger than new sales.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string)"
    field :available, [Money.t()], default: [], derives: "validate(list)"
    field :pending, [Money.t()], default: [], derives: "validate(list)"
  end
end

defmodule MishkaPay.Balance.Transaction do
  @moduledoc """
  One movement of the seller's balance at the provider: a charge, a refund, a fee, a payout.
  Listed with `MishkaPay.list_balance_transactions/3`, such as every one a payout paid out. A
  guarded_struct the provider fills in.

    * `:provider`, `:id`: the provider's id of it (`txn_...` at Stripe).
    * `:amount`: what moved, before fees; below zero when money left the balance.
    * `:fee`: what the provider kept.
    * `:net`: what the balance changed by, `:amount` less `:fee`.
    * `:type`: the provider's own name for it, such as `"charge"`, `"refund"` or `"payout"`.
    * `:source_id`: the provider object it came from, such as a charge or a refund.
    * `:status`: `:available` or `:pending`.
    * `:description`, `:available_at` (when its money is available), `:created_at`.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), derives: "validate(string)"
    field :id, String.t(), derives: "validate(string)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :fee, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :net, Money.t(), validator: {MishkaPay.Money, :signed_field}
    field :type, String.t(), derives: "validate(string)"
    field :source_id, String.t(), derives: "validate(string)"
    field :status, :available | :pending, derives: "validate(enum=Atom[available::pending])"
    field :description, String.t(), derives: "validate(string)"
    field :available_at, DateTime.t(), derives: "validate(struct)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end

defmodule MishkaPay.Balance.Payout do
  @moduledoc """
  Money paid out of an account's balance to its bank account or card (a payout, `po_...` at
  Stripe): the platform's own, or, with a site's keys that name a connected account, the
  seller's. Read with `MishkaPay.fetch_payout/3` and `MishkaPay.list_payouts/3`, and stopped
  with `MishkaPay.cancel_payout/3` while it is still `:pending`. A guarded_struct the provider
  fills in.

    * `:provider`, `:id`.
    * `:amount`: what is paid out.
    * `:status`: `:pending`, `:in_transit`, `:paid`, `:failed` or `:canceled`.
    * `:arrival_at`: when it is expected at the bank, or arrived.
    * `:automatic`: `true` when the provider's payout schedule made it, `false` when someone
      asked for it.
    * `:method`: `"standard"` or `"instant"`.
    * `:destination_id`: the bank account or card it goes to.
    * `:failure_code`, `:failure_message`: why it failed, in the provider's words.
    * `:description`, `:created_at`.

  `MishkaPay.list_balance_transactions/3` with `payout_id:` lists what one automatic payout paid
  out.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true do
    field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
    field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
    field :amount, Money.t(), validator: {MishkaPay.Money, :field}

    field :status, :pending | :in_transit | :paid | :failed | :canceled,
      derives: "validate(enum=Atom[pending::in_transit::paid::failed::canceled])"

    field :arrival_at, DateTime.t(), derives: "validate(struct)"
    field :automatic, boolean(), default: false, derives: "validate(boolean)"
    field :method, String.t(), derives: "validate(string)"
    field :destination_id, String.t(), derives: "validate(string)"
    field :failure_code, String.t(), derives: "validate(string)"
    field :failure_message, String.t(), derives: "validate(string)"
    field :description, String.t(), derives: "validate(string)"
    field :created_at, DateTime.t(), derives: "validate(struct)"
  end
end
