# tailmix Menu

A macOS menu bar app for tailmix. From the menu bar you can:

- connect and disconnect each profile;
- pick an exit node from any connected profile, grouped by profile and, for
  nodes that report a location such as Mullvad, by country and city;
- turn the exit node off and back on (the app remembers the last one);
- open a profile's login page when it needs a login.

It talks to `tailmixd` over its control socket (`/var/run/tailmix/tailmixd.sock`)
and reads the state every few seconds and each time the menu opens.

## Requirements

- macOS 13 or newer
- tailmix installed and running (see the main README)
- Swift 5.9 or newer, from Xcode or the Command Line Tools, to build it

## Build and install

```sh
make macos-app                         # from the repository root
cp -R "macos/TailmixMenu/build/tailmix Menu.app" /Applications/
open "/Applications/tailmix Menu.app"
```

`UNIVERSAL=1 make macos-app` builds for both Apple silicon and Intel Macs, which
needs Xcode. The app is signed ad hoc, so Gatekeeper accepts it only on the
Mac that built it. To run it on another Mac, sign it with your own identity:
`CODESIGN_IDENTITY="Developer ID Application: …"`.

Choose **Open at Login** in the menu to start it automatically.

## Permissions

Anyone can read tailmix's state. Changes need root, except for those made by
one *operator* user. The operator may connect and disconnect profiles and
select or clear the exit node; everything else still needs `sudo`.

The first time you use the app, choose **Allow <you> to Control tailmix…** and
enter an administrator password. This runs `tailmix operator set <your uid>`.
You can also do it in a terminal:

```sh
sudo tailmix operator set       # the user who ran sudo
tailmix operator show
sudo tailmix operator clear
```

## Develop

The package has two targets:

- `TailmixKit` contains the control API client, its JSON models and the menu
  model. It does not depend on AppKit, so its tests also run on Linux:
  `make macos-app-test`.
- `TailmixMenu` contains the AppKit status item and menu.

To use another daemon socket directory, run
`defaults write io.github.maisem.tailmix.menu SocketDirectory /path/to/dir`.
