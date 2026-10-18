{
  pkgs,
  lib,
  modules,
  revision ? "main",
}:
let
  repository = "https://github.com/aldur/nixos-crostini";
  sourcePrefix = toString ../. + "/";
  # Do not make a second reference for the default module alias.
  namedModules = removeAttrs modules [ "default" ];
  publicModules = lib.filterAttrs (
    name: module: name != "default" || !(lib.elem module (lib.attrValues namedModules))
  ) modules;
  references = lib.mapAttrs (
    _: module:
    let
      evaluation = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          module
          { system.stateVersion = lib.mkDefault lib.trivial.release; }
        ];
      };
    in
    pkgs.nixosOptionsDoc {
      inherit revision;
      warningsAreErrors = true;
      # NixOS also exposes the old users.extraUsers alias.
      options = evaluation.options // {
        users = removeAttrs evaluation.options.users [ "extraUsers" ];
      };
      transformOptions =
        option:
        let
          declarations = lib.filter (lib.hasPrefix sourcePrefix) option.declarations;
        in
        option
        // {
          # Include new repository options automatically. Exclude NixOS
          # options whose types this module only extends, such as users.users.
          visible = option.visible && declarations != [ ] && declarations == option.declarations;
          declarations = map (
            path:
            let
              name = lib.removePrefix sourcePrefix path;
            in
            {
              inherit name;
              url = "${repository}/blob/${revision}/${name}";
            }
          ) declarations;
        };
    }
  ) publicModules;
  bookConfig = (pkgs.formats.toml { }).generate "book.toml" {
    book = {
      title = "nixos-crostini module reference";
      language = "en";
      src = "src";
    };
    output.html = {
      git-repository-url = repository;
      site-url = "/nixos-crostini/";
    };
  };
  summary = pkgs.writeText "SUMMARY.md" (
    "# Summary\n\n- [Module reference](index.md)\n"
    + lib.concatMapStrings (name: "- [${name}](${name}.md)\n") (lib.attrNames references)
  );
in
pkgs.runCommand "nixos-crostini-docs"
  {
    nativeBuildInputs = [ pkgs.mdbook ];
  }
  ''
    mkdir -p book/src
    cp ${bookConfig} book/book.toml
    cp ${./index.md} book/src/index.md
    cp ${summary} book/src/SUMMARY.md
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: reference: ''
        cat > book/src/${name}.md <<'EOF'
        # nixosModules.${name}

        [Download option data](${name}-options.json).

        EOF
        cat ${reference.optionsCommonMark} >> book/src/${name}.md
      '') references
    )}
    mdbook build book --dest-dir "$out"
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: reference: ''
        cp ${reference.optionsJSON}/share/doc/nixos/options.json "$out/${name}-options.json"
      '') references
    )}
  ''
