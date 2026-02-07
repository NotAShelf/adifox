# Adifox

[Adios]: https://github.com/adisbladis/adios
[Schizofox]: https://github.com/schizofox/schizofox

This is an [Adios] based Firefox wrapper implementation, hopefully fully on-par
with Nixpkgs' `wrapFirefox` designed to be used with my own project, [Schizofox]
but made standalone to provide a complete, Adios-based Firefox wrapper for those
interested.

## Features

Adifox, bootstrapped by `wrapAdifox.nix`, provides full feature parity with
Nixpkgs' `wrapFirefox` as much as my time and energy allows. Currently, the
features I've fully confirmed working are:

- **Application configuration**: `applicationName`, `pname`, `version`,
  `nameSuffix`, `icon`, `wmClass`
- **Extensions**: `nativeMessagingHosts`, `pkcs11Modules`, `nixExtensions` (with
  validation)
- **Library support**: `useGlvnd`, platform-conditional libs (Linux/Darwin)
- **Preferences**: `extraPrefs`, `extraPrefsFiles`
- **Policies**: `extraPolicies`, `extraPoliciesFiles` (with JSON merging)
- **Feature flags**: `hasMozSystemDirPatch`, `cfg` support for external config
  (TBD)
- **Build features**: Desktop file generation (Firefox/Thunderbird variants),
  icon handling, `makeWrapper` integration

### Platform Support

As `wrapFirefox` and Adios are both cross-platform, so is Adifox. Both Linux and
Darwin are fully supported including codesigning fixes and `omni.ja` copying.

## Usage

### Basic Wrapper

This is a basic (and hopefully self-contained) example. You're strongly
encouraged to create your own fetching method instead of abusing `fetchGit` like
this. Generally, npins is recommendable.

```nix
{ pkgs ? import <nixpkgs> { }
, adios ? (builtins.fetchGit {
    url = "https://github.com/adisbladis/adios";
    rev = "main"; # Pin to specific commit in production
  }).adios { korora = (builtins.fetchGit {
    url = "https://github.com/adisbladis/adios";
    rev = "main";
  }) + "/types/types.nix"; }
}:

let
  # Nixpkgs module for injecting pkgs
  nixpkgsModule = adios: {
    name = "nixpkgs";
    options = {
      pkgs = {
        type = adios.types.attrs;
      };
    };
  };

  tree = adios {
    name = "root";
    modules = {
      nixpkgs = nixpkgsModule adios;
      wrapAdifox = import ./wrapAdifox.nix adios;
    };
  } {
    options = {
      "/nixpkgs" = { inherit pkgs; };
    };
  };
in
  tree.modules.wrapAdifox {
    package = pkgs.firefox-unwrapped;
  }
```

**Or with flakes:**

Flakes are a more common method of fetching dependencies. It'll look _roughly_
like this:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    adios.url = "github:adisbladis/adios";
  };

  outputs = { nixpkgs, adios, ... }: {
    packages.x86_64-linux.default =
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;

        tree = adios.adios {
          name = "root";
          modules = {
            nixpkgs = adios: {
              name = "nixpkgs";
              options.pkgs.type = adios.types.attrs;
            };
            wrapAdifox = import ./wrapAdifox.nix adios;
          };
        } {
          options."/nixpkgs".pkgs = pkgs;
        };
      in
        tree.modules.wrapAdifox {
          package = pkgs.firefox-unwrapped;
        };
  };
}
```

You'll probably want to use or write some kind of platform abstraction to avoid
instantiating `pkgs` for each platform manually. I'm too lazy to write one for
this example, but you are welcome to create a PR!

### Advanced Configuration

Once you have the tree set up as shown above, you can customize the wrapper:

```nix
tree.modules.wrapAdifox {
  package = pkgs.firefox-unwrapped;
  nameSuffix = "-custom";
  nativeMessagingHosts = [ pkgs.tridactyl-native ];
  cfg = {
    smartcardSupport = true;
    speechSynthesisSupport = false;
  };

  extraPrefs = /* js */ ''
    pref("browser.startup.homepage", "https://example.com");
  '';

  extraPolicies = {
    Homepage.StartPage = "homepage";
  };
}
```

### With Extensions (LibreWolf/unsigned builds only)

```nix
tree.modules.wrapAdifox {
  package = pkgs.librewolf-unwrapped;
  nixExtensions = [
    (pkgs.fetchFirefoxAddon {
      name = "ublock-origin";
      url = "https://example.com/addon.xpi";
      sha256 = "...";
      extid = "uBlock0@raymondhill.net";
    })
  ];
}
```

## Testing

Self-contained validation tests are provided in the `tests/` directory:

- `tests/basic.nix` - Basic wrapper test
- `tests/advanced.nix` - Advanced features test

Tests automatically fetch adios from GitHub and require no local checkout:

```bash
nix-build tests/basic.nix
nix-build tests/advanced.nix
```

## Implementation Notes

- All `defaultFunc` options have access to `{ options, inputs }` for dynamic
  defaults
- Library paths computed from `inputs.nixpkgs.pkgs` for proper lib access
- Browser feature flags extracted from `options.package.*` attributes
- External config support via `cfg` option for NixOS module system
  compatibility. This might be removed or renamed at a later date depending on
  my needs and mood.
- Complete bash `buildCommand` ported from `wrapFirefox` with all platform
  conditionals. This mig
