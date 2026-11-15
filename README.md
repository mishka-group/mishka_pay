# Mishka Pay

A payment SDK for Elixir. Each payment provider is a plugin, so a project adds or removes one without touching the rest of its code. Stripe is the first provider.

- **Providers are plugins.** A provider is a [mishka_installer](https://github.com/mishka-group/mishka_installer) plugin that implements `MishkaPay.Provider`. Anyone can add their own by following the same contract.
- **Works on its own or inside Ash.** The core works on plain structs built with [guarded_struct](https://github.com/mishka-group/guarded_struct). When the project uses [Ash](https://ash-hq.org), the `MishkaPay.Ash` layer adds resources, actions and a webhook inbox.
- **Every extension point is an event.** Credentials per site, checks before a checkout and what happens after a payment go through mishka_installer events, so a host hooks in without changing this library.

> Work in progress. Not released yet.

## License

Apache-2.0. See [LICENSE](LICENSE).
