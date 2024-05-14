{
  description = "Dev environment for zenith";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";

    # 0.12.0
    zls_dep.url = "github:NixOS/nixpkgs/5fd8536a9a5932d4ae8de52b7dc08d92041237fc";

    # 0.12.0
    zig_dep.url = "github:NixOS/nixpkgs/5fd8536a9a5932d4ae8de52b7dc08d92041237fc";
  };

  outputs = { self, flake-utils, zig_dep, zls_dep }@inputs :
    flake-utils.lib.eachDefaultSystem (system:
    let
      zig_dep = inputs.zig_dep.legacyPackages.${system};
      zls_dep = inputs.zls_dep.legacyPackages.${system};
    in
    {
      devShells.default = zig_dep.mkShell {
        packages = [
          zig_dep.xxd
          zig_dep.zig
          zls_dep.zls
        ];

        shellHook = ''
          xxd --version 2>&1
          echo 'zls' "$(zls --version)"
          echo 'zig' "$(zig version)"
        '';
      };
    });
}
