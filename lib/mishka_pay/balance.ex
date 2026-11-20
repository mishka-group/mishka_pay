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

    sub_field :transaction, struct(),
      authorized_fields: true,
      doc: """
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
      """ do
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

    sub_field :payout, struct(),
      authorized_fields: true,
      doc: """
      Money paid out of an account's balance to its bank account or card (a payout, `po_...` at
      Stripe): the platform's own, or, with a site's keys that name a connected account, the
      seller's. Made with `MishkaPay.create_payout/1`, read with `MishkaPay.fetch_payout/3` and
      `MishkaPay.list_payouts/3`, and stopped with `MishkaPay.cancel_payout/3` while it is still
      `:pending`. A guarded_struct.

      What the caller gives to make one:

        * `:provider`, `:tenant`: which provider, with whose keys.
        * `:amount` (required): how much, as money, above zero, from the available balance of
          that currency.
        * `:reference` (required): the host's own id for it: it makes the idempotency key, so the
          same reference never pays out twice, and it comes back on every read.
        * `:method`: `"standard"` or `"instant"`, as the provider allows; left out, the provider's
          default (standard at Stripe). An instant payout goes to a card or bank account that
          takes one, for a fee.
        * `:destination_id`: the bank account or card to send it to
          (`MishkaPay.list_payout_destinations/3`); left out, the account's default for the
          currency.
        * `:statement_descriptor`: the words on the bank statement, up to 22 characters.
        * `:description`, `:metadata`.

      What the provider fills in:

        * `:provider`, `:id`.
        * `:amount`: what is paid out.
        * `:status`: `:pending`, `:in_transit`, `:paid`, `:failed` or `:canceled`.
        * `:arrival_at`: when it is expected at the bank, or arrived.
        * `:automatic`: `true` when the provider's payout schedule made it, `false` when someone
          asked for it.
        * `:method`: `"standard"` or `"instant"`.
        * `:destination_id`: the bank account or card it goes to.
        * `:failure_code`, `:failure_message`: why it failed, in the provider's words.
        * `:reference`, `:statement_descriptor`, `:description`, `:metadata`, `:created_at`.

      `MishkaPay.list_balance_transactions/3` with `payout_id:` lists what one automatic payout paid
      out.
      """ do
      field :provider, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

      field :tenant, term()
      field :id, String.t(), derives: "validate(string, not_empty)"
      field :amount, Money.t(), validator: {MishkaPay.Money, :field}

      field :reference, String.t(),
        derives: "sanitize(trim) validate(string, not_empty, max_len=200)"

      field :statement_descriptor, String.t(),
        derives: "sanitize(trim) validate(string, not_empty, max_len=22)"

      dynamic_field :metadata, validator: {MishkaPay.Checkout, :metadata}

      field :status, :pending | :in_transit | :paid | :failed | :canceled,
        derives: "validate(enum=Atom[pending::in_transit::paid::failed::canceled])"

      field :arrival_at, DateTime.t(), derives: "validate(struct)"
      field :automatic, boolean(), default: false, derives: "validate(boolean)"
      field :method, String.t(), validator: {MishkaPay.Balance, :method}
      field :destination_id, String.t(), derives: "sanitize(trim) validate(string, not_empty)"
      field :failure_code, String.t(), derives: "validate(string)"
      field :failure_message, String.t(), derives: "validate(string)"
      field :description, String.t(), derives: "validate(string)"
      field :created_at, DateTime.t(), derives: "validate(struct)"
    end

    sub_field :payout_schedule, struct(),
      authorized_fields: true,
      doc: """
      When an account's available balance is paid out to its bank by itself, read with
      `MishkaPay.fetch_payout_schedule/2` and changed with `MishkaPay.update_payout_schedule/1`:
      the platform's own account, or the connected account a site's keys name. A change sends only
      the fields it gives; each left out stays as the provider has it. A guarded_struct.

        * `:provider`, `:tenant`: which provider, with whose keys.
        * `:interval`: `:manual` (only `MishkaPay.create_payout/1` pays out), `:daily`, `:weekly` or
          `:monthly`.
        * `:weekly_days`: with `:weekly`, the days it pays out, from `:monday` to `:friday`.
        * `:monthly_days`: with `:monthly`, the days of the month it pays out, 1 to 31 (a day a
          month does not have is its last day).
        * `:delay_days`: how many days a payment's money waits before it is available (Stripe
          takes up to 31); `:default` gives the provider's own (Stripe's lowest for the account)
          back.
        * `:minimum_balances`: per currency, the money kept in the balance after an automatic
          payout; only what is above it is paid out. `[]` keeps none.
        * `:statement_descriptor`: the words on the bank statement, up to 22 characters.

      What the provider fills in:

        * `:status`: `:enabled`, or `:disabled` while the provider holds the account's payouts.
        * `:minimum_payouts`: per currency, the smallest payout the provider makes, when its API
          says; Stripe's does not (its docs list them), so it is `[]` there.
      """ do
      field :provider, String.t(),
        enforce: true,
        derives: "sanitize(trim) validate(not_nil_value, string, not_empty)"

      field :tenant, term()

      field :interval, :manual | :daily | :weekly | :monthly,
        derives: "validate(enum=Atom[manual::daily::weekly::monthly])",
        validator: {MishkaPay.Balance, :interval}

      field :weekly_days, list(), validator: {MishkaPay.Balance, :weekly_days}
      field :monthly_days, list(), validator: {MishkaPay.Balance, :monthly_days}
      field :delay_days, non_neg_integer() | :default, validator: {MishkaPay.Balance, :delay_days}
      field :minimum_balances, list(), validator: {MishkaPay.Balance, :minimum_balances}

      field :statement_descriptor, String.t(),
        derives: "sanitize(trim) validate(string, not_empty, max_len=22)"

      field :status, :enabled | :disabled, derives: "validate(enum=Atom[enabled::disabled])"
      field :minimum_payouts, list(), default: [], derives: "validate(list)"
    end

    sub_field :payout_destination, struct(),
      authorized_fields: true,
      doc: """
      A bank account or card an account's payouts go to (an external account, `ba_...` or
      `card_...` at Stripe), read with `MishkaPay.list_payout_destinations/3` and
      `MishkaPay.fetch_payout_destination/3`; a payout's `:destination_id` names one. A
      guarded_struct the provider fills in.

        * `:provider`, `:id`.
        * `:type`: `:bank_account` or `:card`.
        * `:bank_name`: the bank's name, for a bank account; `:card_brand` for a card.
        * `:last4`: the last four digits of the account or card number.
        * `:currency`: what it is paid out in; `:country`: where the bank or card is.
        * `:default`: whether payouts in its currency go here when none is named.
        * `:holder_name`: whose it is, when the provider says.
        * `:status`: the provider's own word, such as `"new"`, `"verified"` or `"errored"` (a
          payout to it failed: the account must give a new one).
      """ do
      field :provider, String.t(), enforce: true, derives: "validate(not_nil_value, string)"
      field :id, String.t(), enforce: true, derives: "validate(not_nil_value, string, not_empty)"
      field :type, :bank_account | :card, derives: "validate(enum=Atom[bank_account::card])"
      field :bank_name, String.t(), derives: "validate(string)"
      field :card_brand, String.t(), derives: "validate(string)"
      field :last4, String.t(), derives: "validate(string)"
      field :currency, String.t(), derives: "validate(string)"
      field :country, String.t(), derives: "validate(string)"
      field :default, boolean(), default: false, derives: "validate(boolean)"
      field :holder_name, String.t(), derives: "validate(string)"
      field :status, String.t(), derives: "validate(string)"
    end
  end

  @weekdays ~w(monday tuesday wednesday thursday friday)a

  @doc false
  def method(field, value) when value in [nil, "standard", "instant"], do: {:ok, field, value}
  def method(field, value) when value in [:standard, :instant], do: {:ok, field, to_string(value)}

  def method(field, _value),
    do:
      {:error, field,
       MishkaPay.Messages.text(:choices, field: field, choices: "standard, instant")}

  @doc false
  def interval(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(manual daily weekly monthly)a)

  @doc false
  def weekly_days(field, value), do: MishkaPay.Helpers.Choice.atoms(field, value, @weekdays)

  @doc false
  def monthly_days(field, nil), do: {:ok, field, nil}

  def monthly_days(field, days) when is_list(days) do
    case Enum.all?(days, &(is_integer(&1) and &1 in 1..31)) do
      true -> {:ok, field, days |> Enum.uniq() |> Enum.sort()}
      false -> {:error, field, MishkaPay.Messages.text(:payout_days)}
    end
  end

  def monthly_days(field, _other), do: {:error, field, MishkaPay.Messages.text(:payout_days)}

  @doc false
  def delay_days(field, value) when is_nil(value) or value == :default, do: {:ok, field, value}
  def delay_days(field, "default"), do: {:ok, field, :default}

  def delay_days(field, days) when is_integer(days) and days >= 0, do: {:ok, field, days}

  def delay_days(field, _other), do: {:error, field, MishkaPay.Messages.text(:delay_days)}

  @doc false
  def minimum_balances(field, nil), do: {:ok, field, nil}

  def minimum_balances(field, list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn
      nil, _done ->
        {:halt, minimum_balances(field, :none)}

      money, {:ok, done} ->
        case MishkaPay.Money.field(field, money) do
          {:ok, _field, money} -> {:cont, {:ok, [money | done]}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, all} -> {:ok, field, Enum.reverse(all)}
      error -> error
    end
  end

  def minimum_balances(field, _other),
    do: {:error, field, MishkaPay.Messages.text(:money_field, field: field)}

  @doc """
  Whether a payout schedule's days go with its interval: `:weekly_days` only with `:weekly`,
  `:monthly_days` only with `:monthly`, and each of those intervals with its days.
  """
  @spec schedule_days(MishkaPay.Balance.PayoutSchedule.t()) :: :ok | {:error, Splode.Error.t()}
  def schedule_days(%{interval: :weekly, weekly_days: [_ | _], monthly_days: nil}), do: :ok
  def schedule_days(%{interval: :monthly, monthly_days: [_ | _], weekly_days: nil}), do: :ok

  def schedule_days(%{interval: interval, weekly_days: nil, monthly_days: nil})
      when interval not in [:weekly, :monthly],
      do: :ok

  def schedule_days(_mismatch),
    do: MishkaPay.ProviderKit.invalid(:interval, MishkaPay.Messages.text(:payout_interval_days))
end
