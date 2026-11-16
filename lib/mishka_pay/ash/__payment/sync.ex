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
    def change(changeset, opts, _context) do
      MishkaPay.Ash.provider_change(changeset, opts, &fetch/1, &announce/2)
    end

    defp fetch(changeset) do
      {provider, payment_id, tenant} = MishkaPay.Ash.object_ref(changeset, :payment_id)

      case MishkaPay.fetch_payment(provider, payment_id, tenant) do
        {:ok, %Payment{} = payment} ->
          changeset
          |> Ash.Changeset.force_change_attributes(attributes(payment, tenant))
          |> MishkaPay.Ash.Owner.write(payment.owner)
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
        amount_captured: payment.amount_captured && payment.amount_captured.amount,
        reference: payment.reference,
        customer_id: payment.customer_id,
        customer_email: payment.customer_email,
        customer_name: payment.customer_name,
        card_brand: payment.card_brand,
        card_last4: payment.card_last4,
        failure_code: payment.failure_code,
        failure_message: payment.failure_message,
        disputed: payment.disputed,
        checkout_id: payment.checkout_id,
        price_ids: ids(payment.items, :id),
        product_ids: ids(payment.items, :product_id),
        provider_created_at: payment.created_at,
        synced_at: DateTime.utc_now()
      }
    end

    defp ids(items, field),
      do: items |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # The answer of the listeners does not change the sync: it already happened.
    @doc false
    def announce(%{context: %{mishka_pay_payment: %Payment{} = payment}}, {:ok, record} = result) do
      timeout = Application.get_env(:mishka_pay, :payment_changed_timeout, 5_000)

      _answer =
        Plugins.call(Events.payment_changed(), %{payment: payment, record: record}, timeout)

      result
    end

    # A row changed without the provider's word (a refund counted while the provider could not be
    # read): the announcement waits for the next sync, which brings it.
    def announce(_changeset, error), do: error
  end
end
