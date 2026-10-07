# SPDX-License-Identifier: MIT
{ pkgs }:
let
  inherit (pkgs) lib;
  base = {
    hostname = "mail.realm.test";
    defaultDomain = "realm.test";
    domains = [ "realm.test" "alias.test" "other.test" "local.test" ];
    webPort = 8081;
    acme.enable = false;
    dns.object."@type" = "Manual";
    resolver.object."@type" = "System";
  };
  directory = domain: issuerUrl: aliases: {
    inherit domain issuerUrl aliases;
    audience = "stalwart";
    claimUsername = "preferred_username";
    claimName = null;
    claimGroups = null;
  };
  first = directory "realm.test" "https://login.realm.test/oauth2/openid/mail" [ "alias.test" ];
  second = directory "other.test" "https://login.other.test/oauth2/openid/mail" [ ];
  configured = base // { identityDirectories = { realm = first; other = second; }; };
  assertions = cfg: (import ../nixos/stalwart-identity.nix { inherit lib cfg; }).assertions;
  accepts = cfg: builtins.all (assertion: assertion.assertion) (assertions cfg);
  invalid = directory: configured // { identityDirectories = { realm = first; other = directory; }; };
  mkPlan = cfg: import ../nixos/stalwart-plan.nix {
    inherit pkgs lib cfg;
    stalwartWebui = pkgs.writeTextDir "webui.zip" "fixture";
  };
  rejectsPlan = cfg: !(builtins.tryEval (mkPlan cfg).drvPath).success;
  plan = mkPlan configured;
  empty = mkPlan (base // { identityDirectories = { }; });
in
assert accepts configured;
assert rejectsPlan (invalid (second // { issuerUrl = first.issuerUrl; }));
assert rejectsPlan (invalid (second // { aliases = [ "alias.test" ]; }));
assert !(accepts (invalid (second // { issuerUrl = first.issuerUrl; })));
assert !(accepts (invalid (second // { aliases = [ "alias.test" ]; })));
assert !(accepts (invalid (second // { aliases = [ "missing.test" ]; })));
assert !(accepts (invalid (second // { aliases = [ "other.test" ]; })));
assert !(accepts (invalid (second // { issuerUrl = "http://login.other.test"; })));
pkgs.runCommand "stalwart-canonical-identity-plan" { nativeBuildInputs = [ pkgs.jq ]; } ''
  jq --slurp --exit-status '
    map(select(.object == "Directory")) as $directories |
    (map(select(.object == "Domain"))[0].value) as $domains |
    ($directories | length == 2) and
    (all($directories[]; ."@type" == "reconcile" and .matchOn == ["description"] and
      .scope."@type" == "Oidc" and (.value | length == 1) and
      (.scope.issuerUrl as $issuer | all(.value[]; .issuerUrl == $issuer)))) and
    ($directories[0].value["directory-kanidm-other-test"].usernameDomain == "other.test") and
    ($directories[1].value["directory-kanidm-realm-test"].usernameDomain == "realm.test") and
    ($domains["domain-realm-test"].directoryId == "#directory-kanidm-realm-test") and
    ($domains["domain-alias-test"].directoryId == "#directory-kanidm-realm-test") and
    ($domains["domain-other-test"].directoryId == "#directory-kanidm-other-test") and
    ($domains["domain-local-test"] | has("directoryId") | not) and
    (map(.object) | index("Directory") < index("Domain")) and
    (all(.[]; ."@type" != "destroy")) and
    (map(select(.object == "NetworkListener" and ."@type" == "upsert"))[0].value as $listeners |
      ($listeners | has("listener-https") | not) and
      $listeners["listener-http"].bind == {"127.0.0.1:8081": true} and
      $listeners["listener-imaps"].tlsImplicit == true and
      $listeners["listener-submissions"].tlsImplicit == true) and
    (map(select(.object == "NetworkListener" and ."@type" == "reconcile"))[0] |
      .scope == {"name": "https"} and .value == {} and .matchOn == ["name"])
  ' ${plan}
  jq --slurp --exit-status 'map(select(.object == "Directory")) | length == 0' ${empty}
  touch $out
''
