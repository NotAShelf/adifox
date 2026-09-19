let
  # FIXME: pin this
  lladiosSource = builtins.fetchTarball "https://github.com/llakala/lladios/archive/main.tar.gz";
  lladios = import lladiosSource;

  pkgs = import <nixpkgs> {};

  # Nixpkgs module
  nixpkgsModule = lladios: {
    name = "nixpkgs";
    options = {
      pkgs = {
        type = lladios.types.attrs;
      };
      lib = {
        type = lladios.types.attrs;
        defaultFunc = { options }: options.pkgs.lib;
      };
    };
  };

  # Create tree by calling lladios with root module definition then options
  tree =
    lladios {
      name = "root";
      modules = {
        nixpkgs = nixpkgsModule lladios;
        wrapAdifox = import ../wrapAdifox.nix lladios;
      };
    } {
      options = {
        "/nixpkgs" = {inherit pkgs;};
      };
    };
in
  # Call the wrapper with Firefox
  tree.modules.wrapAdifox {
    package = pkgs.firefox-unwrapped;
  }
