# Many sites

Mishka Pay is built for one install that serves many sites, as Mishka CMS does.

1. **Keys per site.** The keys plugin answers each site's own keys and settings (refunds once or
   many, merchant of record, Stripe Tax) from its database, at runtime. Changing a site's keys
   needs no restart.
2. **Every call names the site.** `tenant: site.id` on every call (`MishkaPay.checkout/1`,
   `MishkaPay.fetch_payment/3`...).
3. **Webhooks per site.** Each site's Stripe endpoint is `/pay/webhooks/stripe/<site id>`; the
   signature is checked with that site's `webhook_secret`, and the event carries the site.
4. **Ash multitenancy.** Your Mishka Pay resources may use Ash multitenancy on your own attribute:

   ```elixir
   multitenancy do
     strategy :attribute
     attribute :site_id
   end
   ```

   Actions then run with `tenant: site.id`, the provider's keys are read for that site, and each
   webhook's row is synced inside the site its URL names. The same Stripe object in two sites is two
   rows. Keep the inbox global: a webhook arrives before any site is chosen.

   Without Ash multitenancy, name your own column instead, and each create action writes the
   site there too:

   ```elixir
   mishka_pay do
     kind :payment
     tenant_from :site_id
   end

   relationships do
     belongs_to :site, MyApp.Sites.Site
   end
   ```
5. **Real time per site.** `MishkaPay.PubSub` broadcasts on each site's own topic; subscribe a
   site's admin to `MishkaPay.PubSub.topic(:payment, site.id)`.
