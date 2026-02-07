let
  # FIXME: pin this
  adiosSource = builtins.fetchTarball "https://github.com/adisbladis/adios/archive/master.tar.gz";
  adios = (import adiosSource).adios;

  pkgs = import <nixpkgs> {};

  # Nixpkgs module
  nixpkgsModule = adios: {
    name = "nixpkgs";
    options = {
      pkgs = {
        type = adios.types.attrs;
      };
    };
  };

  # Create tree by calling adios with root module definition then options
  tree =
    adios {
      name = "root";
      modules = {
        nixpkgs = nixpkgsModule adios;
        wrapAdifox = import ../wrapAdifox.nix adios;
      };
    } {
      options = {
        "/nixpkgs" = {inherit pkgs;};
      };
    };
in
  # Test with various options
  tree.modules.wrapAdifox {
    browser = pkgs.firefox-unwrapped;
    nameSuffix = "-custom";
    extraPrefs = ''
      pref("browser.startup.homepage", "https://example.com");
    '';
    extraPolicies = {
      Homepage = {
        StartPage = "homepage";
      };
    };
    nativeMessagingHosts = [pkgs.tridactyl-native];
  }
