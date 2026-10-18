{ pkgs }:
pkgs.runCommand "workflow-security"
  {
    nativeBuildInputs = [
      pkgs.actionlint
      pkgs.zizmor
    ];
  }
  ''
    cp -r ${../.github} .github
    actionlint .github/workflows/*.yml
    zizmor --offline --persona=pedantic --strict-collection .github
    touch "$out"
  ''
