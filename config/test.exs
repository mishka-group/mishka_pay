# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

# The plugin registry of a test run, on disk under the project and out of git (`.gitignore`).
config :mishka_installer, MishkaInstaller.MnesiaRepo,
  mnesia_dir: Path.expand("../.mnesia/test", __DIR__),
  essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]

# Keep the run quiet: the installer logs every registry step at debug and info.
config :logger, level: :warning

# Every provider call of a test is answered by `MishkaPay.Test.stub_http/1`.
config :mishka_pay, req_options: [plug: {Req.Test, MishkaPay.Client}]
