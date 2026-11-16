# Getting started

## Install

```bash
mix igniter.install mishka_pay              # add --ash for the Ash layer, --pubsub for broadcasts
```

or by hand: add `{:mishka_pay, "~> 0.0.1-alpha.1"}` (a pre-release is matched only when named),
supervise `MishkaPay.Registry` (mishka_installer's plugin registry, started only where nothing
else starts it), then `MishkaPay.Providers.Stripe` and your keys plugin, mount `plug MishkaPay.Webhook, at:
"/pay/webhooks"` before `Plug.Parsers`, and give mishka_installer's plugin registry a folder per
environment:

```elixir
config :mishka_installer, MishkaInstaller.MnesiaRepo,
  mnesia_dir: Path.expand("../.mnesia/#{config_env()}", __DIR__),
  essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]
```

## Keys, per site

Mishka Pay never reads keys from `config.exs`. A keys plugin answers them at runtime, for each
provider and tenant:

```elixir
defmodule MyApp.Pay.Keys do
  use MishkaPay.Credentials

  @impl MishkaPay.Credentials
  def credentials("stripe", site_id) do
    case MyApp.Sites.payment_settings(site_id) do
      %{stripe_secret_key: key} = s when is_binary(key) ->
        %{secret_key: key, webhook_secret: s.stripe_webhook_secret, refunds: :once,
          automatic_tax: s.stripe_tax?, merchant_of_record: s.merchant_of_record}

      _no_keys ->
        nil
    end
  end

  def credentials(_provider, _site_id), do: nil
end
```

Fields: `secret_key` (required), `publishable_key`, `webhook_secret`, `mode` (`:test` or
`:live`), `merchant_of_record`, `automatic_tax`, `refunds` (`:once` or `:many`), `extra`. Answer
`nil` for a site without keys; the call is then `MishkaPay.Errors.MissingCredentials`.

## Sell once

```elixir
{:ok, checkout} =
  MishkaPay.checkout(%{
    provider: "stripe",
    tenant: site.id,
    items: [%{name: "Elixir ebook", amount: %{amount: "19.99", currency: "USD"},
              tax_code: "txcd_10302000"}],
    success_url: url(~p"/thanks") <> "?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: url(~p"/cart"),
    reference: order.id,
    customer: %{email: user.email}
  })
```

`reference` is your order id: the same reference never opens two checkouts, and it comes back on
the payment. Read the payment back before you give anything:

```elixir
{:ok, %{payment_id: pi}} = MishkaPay.fetch_checkout("stripe", session_id, site.id)
{:ok, %MishkaPay.Payment{status: :paid}} = MishkaPay.fetch_payment("stripe", pi, site.id)
```

## Sell a plan

A subscription is a checkout with `mode: :subscription` and items with an `interval`:

```elixir
MishkaPay.checkout(%{..., mode: :subscription, trial_days: 14,
  items: [%{name: "Pro", amount: %{amount: "20", currency: "USD"}, interval: :month}]})
```

Change it later with `MishkaPay.change_subscription/1` (preview first with
`MishkaPay.preview_subscription_change/1`), cancel it with `MishkaPay.cancel_subscription/4`.

## What else

Customers and their portal (`MishkaPay.create_customer/1`, `MishkaPay.portal_session/1`),
coupons and promotion codes, the catalog (`MishkaPay.create_product/1`, `MishkaPay.create_price/1`),
payment links (`MishkaPay.create_payment_link/1`), disputes, and every list page by page
(`MishkaPay.Page`). `usage-rules.md` lists every call.
