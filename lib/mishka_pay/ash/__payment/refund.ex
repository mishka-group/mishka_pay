# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.Refund do
    @moduledoc """
    The `:refund` action of `MishkaPay.Ash.Payment`: refunds the stored payment through its
    provider before the transaction starts (once: a row that shows a refund is refused without
    asking the provider), reads the payment again and writes it, keeps the
    `MishkaPay.Refund` in the record's `:refund` metadata, and fires `mishka_pay:payment:changed`.
    When the payment cannot be read again, the row counts the refund itself (never past the
    payment's amount), and the announcement waits for the next sync.
    """

    use Ash.Resource.Change

    alias MishkaPay.Ash.Payment.Sync

    @impl true
    def change(changeset, _opts, _context) do
      changeset
      |> Ash.Changeset.before_transaction(&refund/1)
      |> Ash.Changeset.after_action(fn changeset, record ->
        {:ok, Ash.Resource.put_metadata(record, :refund, changeset.context[:mishka_pay_refund])}
      end)
      |> Ash.Changeset.after_transaction(&Sync.announce/2)
    end

    defp refund(%{data: payment} = changeset) do
      case Decimal.gt?(payment.amount_refunded, 0) do
        true ->
          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Changes.InvalidChanges.exception(
              fields: [:amount],
              message: MishkaPay.Messages.text(:refund_once)
            )
          )

        false ->
          provider_refund(changeset, payment)
      end
    end

    defp provider_refund(changeset, payment) do
      request = %{
        provider: payment.provider,
        tenant: payment.tenant,
        payment_id: payment.provider_id,
        amount: Ash.Changeset.get_argument(changeset, :amount),
        reason: Ash.Changeset.get_argument(changeset, :reason)
      }

      case MishkaPay.refund(request) do
        {:ok, refund} ->
          changeset
          |> Ash.Changeset.put_context(:mishka_pay_refund, refund)
          |> refreshed(payment, refund)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, MishkaPay.Ash.to_ash_error(error))
      end
    end

    # The money already moved, so the action succeeds either way: with the provider's payment when
    # it answers, or with the refund counted here until the next sync.
    defp refreshed(changeset, payment, refund) do
      case MishkaPay.fetch_payment(payment.provider, payment.provider_id, payment.tenant) do
        {:ok, fresh} ->
          changeset
          |> Ash.Changeset.force_change_attributes(Sync.attributes(fresh, payment.tenant))
          |> Ash.Changeset.put_context(:mishka_pay_payment, fresh)

        {:error, _cannot_read} ->
          Ash.Changeset.force_change_attributes(changeset, counted(payment, refund))
      end
    end

    defp counted(payment, refund) do
      refunded =
        case refund.amount do
          %Money{amount: amount} ->
            payment.amount_refunded |> Decimal.add(amount) |> Decimal.min(payment.amount)

          nil ->
            payment.amount
        end

      status =
        case Decimal.compare(refunded, payment.amount) do
          :lt -> :partially_refunded
          _all -> :refunded
        end

      %{amount_refunded: refunded, status: status}
    end
  end
end
