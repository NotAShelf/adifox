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
  # Call the wrapper with Firefox
  tree.modules.wrapAdifox {
    package = pkgs.firefox-unwrapped;
  }
