# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Payment.Sync do
    @moduledoc """
    Reads a payment from its provider before the action's transaction starts and writes what the
    provider said; after the transaction, fires `mishka_pay:payment:changed`. A payment the
    provider cannot give is an error on the action, and nothing is written.
    """

    use Ash.Resource.Change

    alias MishkaPay.{Events, Payment}
    alias MishkaPay.Helpers.Plugins

    @impl true
    def change(changeset, _opts, _context) do
      changeset
      |> Ash.Changeset.before_transaction(&fetch/1)
      |> Ash.Changeset.after_transaction(&announce/2)
    end

    defp fetch(changeset) do
      provider = Ash.Changeset.get_argument(changeset, :provider)
      payment_id = Ash.Changeset.get_argument(changeset, :payment_id)
      tenant = Ash.Changeset.get_argument(changeset, :tenant)

      case MishkaPay.fetch_payment(provider, payment_id, tenant) do
        {:ok, %Payment{} = payment} ->
          changeset
          |> Ash.Changeset.force_change_attributes(attributes(payment, tenant))
          |> Ash.Changeset.put_context(:mishka_pay_payment, payment)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, MishkaPay.Ash.to_ash_error(error))
      end
    end

    @doc false
    def attributes(payment, tenant) do
      %{
        provider: payment.provider,
        provider_id: payment.id,
        tenant: tenant,
        status: payment.status,
        amount: payment.amount.amount,
        amount_refunded:
          (payment.amount_refunded || Money.new(payment.amount.currency, 0)).amount,
        currency: to_string(payment.amount.currency),
        reference: payment.reference,
        customer_id: payment.customer_id,
        provider_created_at: payment.created_at,
        synced_at: DateTime.utc_now()
      }
    end

    # The answer of the listeners does not change the sync: it already happened.
    @doc false
    def announce(changeset, {:ok, record} = result) do
      payment = changeset.context[:mishka_pay_payment]
      timeout = Application.get_env(:mishka_pay, :payment_changed_timeout, 5_000)

      _answer =
        Plugins.call(Events.payment_changed(), %{payment: payment, record: record}, timeout)

      result
    end

    def announce(_changeset, error), do: error
  end
end
