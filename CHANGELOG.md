# Changelog

## 0.0.4

- PayPal: a checkout line takes the seller's own tax as a percentage (`tax_percentage`, held in the amount with `tax_behavior: :inclusive`): a one-time Order sends it on each item with its `tax_total` and reads it back as the checkout's `amount_tax`, and a subscription's plan carries it. Stripe refuses it and keeps taking rates (`tax_rate_ids`).
- PayPal: a reversed capture and a buyer's dispute make the payment `disputed`, so a shop takes the access back as for a Stripe chargeback; the dispute webhooks (`CUSTOMER.DISPUTE.*`) name the Order of the capture they hold.
- PayPal: a webhook signed more than 300 seconds from now (`webhook_tolerance`), or naming a certificate off PayPal's own API hosts, is refused with 400 before PayPal is asked.
- Stripe: a payment says how risky Radar found it (`risk_level`, `risk_score`) and carries its charge's open or closed review (`fraud_review`).
- Stripe: a checkout's own `metadata` goes on its PaymentIntent and subscription too, so it comes back on the payment (`MishkaPay.Payment` `:metadata`).
- Stripe: a coupon takes the products it is for (`product_ids`, Stripe's `applies_to.products`), so Stripe keeps a code to them on its own page too.
- Stripe: a read-back checkout names the discounts it applied (`discounts`), a code the buyer typed in the page's box included.
- Stripe: an invoice read or listed names the PaymentIntent that paid it (`payment_id`; Stripe leaves `payments` out unless asked), and `list_invoices/3` takes `status:`, so `status: :paid, limit: 1` is a subscription's latest paid bill.

## 0.0.3

- A subscription says when its card expires (`card_exp_month`, `card_exp_year`), read from the provider and kept on the synced row, so a host can warn a buyer before the card stops working.
- Built and tested against the newest Ash (3.38) and the newest of every other dependency.
- Needs mishka_installer 0.1.18, which checks an extension archive before it unpacks it

## 0.0.2

- Payouts: pay the balance out now, read and set the payout schedule, and read the bank accounts payouts go to.
- A payment names its charge, balance movement and fee, and each balance movement names its payment.
- Webhooks record how long each answer took and count refused messages without their bodies; every answer but 200 logs one plain line saying why.
- Tax: a registration starting earlier today is sent as Stripe's `now`; one from an earlier day is refused before any request.
- PayPal: a sale goes end to end like a Stripe one, from one return page to its refund's webhook.
- Checkout: the idempotency key comes from the reference and the params, so a checkout asked again with other details is a new request; a Stripe line with its own amount names a product Stripe already has, so its tax code applies; a checkout may name the only ways to pay it offers (`allowed_payment_method_types`), which PayPal refuses.
- A subscription carries the card of its default payment method; the subscription kind keeps its brand and last four.
- A price keeps its amount in other currencies (`currency_options`), and a checkout charges the currency it names.
- Inbox: an event that failed can be skipped with who and why, is never tried again, and can be brought back as failed (`:skip`, `:bring_back`).

## 0.0.1

- Initial version: [mishka.tools/pay](https://mishka.tools/pay)
