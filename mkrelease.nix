with import ./devnixlib.nix;

rec {

mkRelease =
    { pkgs ? import <nixpkgs> {}
    , parameters ? {}
    , addSrcs ? {}: {}
    , gitTree ? null
    , gitTreeAdj ? null
    , srcs ? {}
    , overrides ? {}
    }:
  let

  ghcver = parameters.ghcver or "ghc864";
  variant = parameters.variant or "master";

  hpkgs =
    pkgs.haskell.packages."${ghcver}".extend(
      (pkgs.lib.composeExtensions hSources overrides.haskell-packages));


  # Alternative: construct the { type="git", ... } entry to match all the others.
  projectSources = f:
    # Method 2: deconstruct URL to create a { type="git", ... } source
    # description.
    #   + maintains context
    #   - conversion away from url, with githubSrc moving back
    #   - still need to reverse the "-src" added by gitTreeSources.
    let d = let
              eachGitSrc = if gitTreeAdj == null then gitsrcref
                           else a: gitsrcref (gitTreeAdj a);
              gitsrcref = { name, url, rev }:
                let splt = gitURLSplit url; in
                { name = "${name}";
                  value = { type = "github"; team = splt.team; repo = splt.repo; ref = rev; };
                };
              gtree = gitTreeSources 2 eachGitSrc gitTree;
            in builtins.listToAttrs gtree;
        s = addSrcs parameters;
        r = builtins.removeAttrs (f s) [ "freshHaskellHashes" ];
        o = builtins.intersectAttrs r d;  # d.x, but only where x is also in r
    in overridePropagatingAttrs [ "subpath" ] r o;

  allProjectSources =
    let f = s: builtins.removeAttrs s [ "haskell-packages" ] // s.haskell-packages;
    in projectSources f;

  haskellProjectSources = let f = s: s.haskell-packages; in projectSources f;

  isSrcURL = n: v: builtins.typeOf v == "string" && startsWith "https://" v;

  projectSourceTargetNames = prjSrcs:
    let gs = builtins.attrNames (gitSources prjSrcs);
        srcUrls = filterAttrs isSrcURL prjSrcs;
        srcTgts = builtins.attrNames srcUrls;
    in gs ++ srcTgts;

  hSources = pkgs.haskell.lib.packageSourceOverrides hSrcOverrides;

  hSrcOverrides =
    let sl = mapAttrs toSrc (projectSourceOverrides haskellProjectSources);
        toSrc = n: v: requireAttrValuePath { name = n; value = v; };
    in builtins.listToAttrs sl;

  requireAttrValuePath = { name, value } @ a:
    let isP = builtins.typeOf value == "path";
        r = builtins.tryEval (builtins.pathExists value);
        exists = r.success && r.value;
        ckP = if exists then a
              else abort "Path for ${name} does not exist: ${value}";
    in builtins.deepSeq isP (if isP then (builtins.deepSeq ckP ckP) else a);

  # There are three possible specifications of sources: the default
  # set from the configs (addSrcs), any information obtained by a
  # gitTree analysis, and any overrides supplied via the command line
  # (e.g. by the user or by hydra input evaluations).  The value used
  # should be in this order, respectively, with the command line
  # inputs overriding all others, but modified by any additional
  # fields (such as subpath).
  projectSourceOverrides = prjSrcs:
    let mkSrcOvr = n: s:
          if builtins.typeOf s == "string"
          then stringOvr n s
          else
          if s.type == "github"
          then githubOvr n s
          else if s.type == "hackageVersion"
               then { name = n; value = s.version; }
               else throw ("Unknown project source type: " + s.type);
        stringOvr = n: v:
          if isSrcURL n v
          then { name = n; value = githubSrcURL v; }
          else { name = n; value = v; };
        githubOvr = n: v:
          let ghsrc = githubSrc { inherit (v) team repo;
                                  ref = v.ref or "master"; };
              isrc = hasDefAttr (hasDefAttr ghsrc srcs n) srcs "${n}-src";
              extraArgs = withDefAttr "" v "subpath" mkSubpath;
              mkSubpath = p: "/" + p;
              asPath = x: { string = x; path = /. + x; }."${builtins.typeOf x}";
              r = { name = n; value = asPath (isrc + extraArgs); };
          in r;
        srcAttrList = mapAttrs mkSrcOvr prjSrcs;
    in builtins.listToAttrs srcAttrList;

in builtins.listToAttrs
    (map (n: {name = n; value = hpkgs."${n}"; })
          (projectSourceTargetNames allProjectSources))
   // overrides.global;

}
