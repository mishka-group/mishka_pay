# Changelog

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
