{
  pkgs,
  docs,
  modules,
}:
let
  probe = {
    default = 42;
    example = 7;
    description = "Check automatic option discovery.";
  };
  fixture = docs.override {
    revision = "docs-test";
    modules = modules // {
      new-module = {
        _file = toString ./docs.nix;
        options.documentationProbe = pkgs.lib.mkOption (probe // { type = pkgs.lib.types.int; });
      };
    };
  };
  expected = pkgs.writeText "expected-option.json" (
    builtins.toJSON (probe // { type = pkgs.lib.types.int.description; })
  );
in
pkgs.runCommand "module-docs-contract" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python - ${docs} ${fixture} ${expected} <<'PY'
  import json
  import sys
  from html.parser import HTMLParser
  from pathlib import Path
  from urllib.parse import unquote, urlsplit

  site, fixture, expected_file = map(Path, sys.argv[1:])
  expected = json.loads(expected_file.read_text())
  options = json.loads((fixture / "new-module-options.json").read_text())
  assert set(options) == {"documentationProbe"}, options.keys()
  option = options["documentationProbe"]
  for field, value in expected.items():
      actual = option[field]
      if field in ("default", "example"):
          actual = json.loads(actual["text"])
      assert actual == value, (field, actual, value)
  assert option["declarations"]
  assert all(source["url"].endswith("/docs-test/tests/docs.nix") for source in option["declarations"])
  assert "documentationProbe" in (fixture / "new-module.html").read_text()

  class Links(HTMLParser):
      def __init__(self):
          super().__init__()
          self.links = []
          self.ids = set()

      def handle_starttag(self, tag, attrs):
          self.links.extend(value for name, value in attrs if name in ("href", "src") and value)
          self.ids.update(value for name, value in attrs if name == "id" and value)

  for root in (site, fixture):
      pages = list(root.rglob("*.html"))
      assert pages, root
      documents = {}
      for page in pages:
          content = page.read_text()
          assert "/nix/store/" not in content, page
          parser = Links()
          parser.feed(content)
          documents[page.resolve()] = parser
      for page, parser in documents.items():
          for link in parser.links:
              url = urlsplit(link)
              if url.scheme or url.netloc:
                  continue
              path = unquote(url.path)
              if not path:
                  target = page
              elif path.startswith("/nixos-crostini/"):
                  target = root / path.removeprefix("/nixos-crostini/")
              else:
                  assert not path.startswith("/"), (page, link)
                  target = page.parent / path
              assert target.resolve().is_relative_to(root.resolve()), (page, link)
              if target.is_dir():
                  target = target / "index.html"
              assert target.exists(), (page, link)
              if url.fragment and target.suffix == ".html":
                  assert unquote(url.fragment) in documents[target.resolve()].ids, (page, link)
      for data in root.glob("*-options.json"):
          assert "/nix/store/" not in data.read_text(), data
  PY
  touch "$out"
''
