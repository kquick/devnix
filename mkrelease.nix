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
    , hydraRun ? false # if true, ignores githubsrc.local specifications
    }:
let

  ghcver = parameters.ghcver or "ghc864";
  variant = parameters.variant or "master";

  hpkgs =
    let hextends = withDefAttr hSources overrides "haskell-packages"
                   (hpkg: pkgs.lib.composeExtensions hSources (hpkg parameters));
    in pkgs.haskell.packages."${ghcver}".extend(hextends);

  srcSpecialFlags =
    # Special flags present in the addSrcs results that don't represent
    # actual sources but are used to indicate other things.
    [ "freshHaskellHashes" ];

  projectSources = f:
    # Returns the source location for all the source override packages
    # (those returned by calling addSrcs with the current parameters
    # as an argument).  In addition, if there is a gitTree that
    # references that source, deconstruct the URL into a:
    #
    #   { pkgname = githubsrc { type="git"; ... }; ... }
    #
    # Input argument f is a filter to apply to the input source overrides.
    #
    # The result is an attrset of pkgname to githubsrc (or other)
    # source specification for every package no filtered out of the
    # addSrcs set.
    let gittreesrcs =
            let
              eachGitSrc = if gitTreeAdj == null then gitsrcref
                           else a: gitsrcref (gitTreeAdj a);
              gitsrcref = { name, url, rev }:
                let splt = gitURLSplit url; in
                { name = "${name}";
                  value = githubsrc splt.team splt.repo rev;
                };
              gtree = gitTreeSources 2 eachGitSrc gitTree;
            in builtins.listToAttrs gtree;
        srclist = addSrcs parameters;
        real_srclist = builtins.removeAttrs (f srclist) srcSpecialFlags;
        src_overrides =
          # gittreesrcs.x, but only where x is also in real_srclist
          builtins.intersectAttrs real_srclist gittreesrcs;
    in overridePropagatingAttrs [ "subpath" ] real_srclist src_overrides;

  allProjectSources =
    # Every source specified by calling the addSrcs input with the
    # current parameters as an argument.
    #
    # Promotes every entry in the "haskell-packages" portion into the
    # top-level (overriding any previous entry there).
    #
    # Example:
    #   { foo = githubsrc { ..loc_A.. };
    #     haskell-packages = {
    #       foo = githubsrc { ..loc_B.. };
    #       bar = githubsrc { ... };
    #     };
    #   }
    #
    # becomes
    #  { foo = githubsrc { ..loc_B.. };
    #    bar = githubsrc { ... };
    #  }
    let f = s: builtins.removeAttrs s [ "haskell-packages" ] //
               (s.haskell-packages or {});
    in projectSources f;

  haskellProjectSources =
    # Only the haskell sources specified by calling the addSrcs input
    # with the current parameters as an argument and returning
    # everything it specifies under the "haskell-packages" attribute.
    let f = s: s.haskell-packages or {}; in projectSources f;

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
          else if builtins.typeOf s == "path"
          then { name = n; value = s; }
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
          let ghsrc = githubSrcFetch ({ ref = "master"; } // v);
              isrc = hasDefAttr (hasDefAttr ghsrc srcs n) srcs "${n}-src";
              extraArgs = withDefAttr "" v "subpath" mkSubpath;
              mkSubpath = p: "/" + p;
              asPath = x: { string = x; path = /. + x; }."${builtins.typeOf x}";
              r = { name = n; value = asPath (isrc + extraArgs); };
          in if !hydraRun && builtins.hasAttr "local" v then stringOvr n (v.local + extraArgs) else r;
        srcAttrList = mapAttrs mkSrcOvr prjSrcs;
    in builtins.listToAttrs srcAttrList;

  htargets = builtins.listToAttrs
               (map (n: {name = n; value = hpkgs."${n}"; })
                    (projectSourceTargetNames allProjectSources));

  shell_htargets =
    let pkgWithTools = n: pkgs.haskell.lib.addExtraLibraries hpkgs."${n}"
                          [ pkgs.haskell.packages.${ghcver}.cabal-install ];
        pkgAttr = n: { name = n; value = pkgWithTools n; };
    in  builtins.listToAttrs (map pkgAttr (projectSourceTargetNames allProjectSources));

  globaltgts = withDefAttr {} overrides "global" (o: o parameters);

in (if pkgs.lib.inNixShell then shell_htargets else htargets) // globaltgts;

}
