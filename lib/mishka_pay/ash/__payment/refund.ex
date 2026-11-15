# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.Refund do
    @moduledoc """
    The `:refund` action of `MishkaPay.Ash.Payment`: refunds the stored payment through its
    provider before the transaction starts, reads the payment again and writes it, keeps the
    `MishkaPay.Refund` in the record's `:refund` metadata, and fires `mishka_pay:payment:changed`.
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
      request = %{
        provider: payment.provider,
        tenant: payment.tenant,
        payment_id: payment.provider_id,
        amount: Ash.Changeset.get_argument(changeset, :amount),
        reason: Ash.Changeset.get_argument(changeset, :reason),
        reference: Ash.Changeset.get_argument(changeset, :reference)
      }

      with {:ok, refund} <- MishkaPay.refund(request),
           {:ok, fresh} <-
             MishkaPay.fetch_payment(payment.provider, payment.provider_id, payment.tenant) do
        changeset
        |> Ash.Changeset.force_change_attributes(Sync.attributes(fresh, payment.tenant))
        |> Ash.Changeset.put_context(:mishka_pay_refund, refund)
        |> Ash.Changeset.put_context(:mishka_pay_payment, fresh)
      else
        {:error, error} -> Ash.Changeset.add_error(changeset, MishkaPay.Ash.to_ash_error(error))
      end
    end
  end
end
