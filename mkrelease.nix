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

  ghcver = parameters.ghcver or "ghc865";
  variant = parameters.variant or "master";

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
    # source specification for every package not filtered out of the
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
    #     cow = githubsrc { ..loc_C.. };
    #     haskell-packages = {
    #       foo = githubsrc { ..loc_B.. };
    #       bar = githubsrc { ... };
    #     };
    #   }
    #
    # becomes
    #  { foo = githubsrc { ..loc_B.. };
    #    bar = githubsrc { ... };
    #    cow = githubsrc { ..loc_C.. };
    #  }
    let f = s: builtins.removeAttrs s [ "haskell-packages" ] //
               (s.haskell-packages or {});
    in projectSources f;

  projectSourceTargetNames = prjSrcs:
    let gs = builtins.attrNames (gitSources prjSrcs);
        srcUrls = filterAttrs isURLValue prjSrcs;
        srcTgts = builtins.attrNames srcUrls;
    in gs ++ srcTgts;

  # There are three possible specifications of sources: the default
  # set from the configs (addSrcs), any information obtained by a
  # gitTree analysis, and any overrides supplied via the command line
  # (e.g. by the user or by hydra input evaluations).  The value used
  # should be in this order, respectively, with the command line
  # inputs overriding all others, but modified by any additional
  # fields (such as subpath).
  projectSourceOverrides = prjSrcs:
    let mkSrcOvr = n: s:
          let loc = if      builtins.typeOf s == "string"         then stringOvr n s
                    else if builtins.typeOf s == "path"           then pathOvr n s
                    else if s.type            == "github"         then githubOvr n s
                    else if s.type            == "hackageVersion" then hackageOvr n s
                    else throw ("Unknown project source type: " + s.type);
              inp_src = i: pathOvr n (plusSubpath i s);
          in withDefAttr loc srcs "${n}-src" inp_src;
        plusSubpath = pth: attrval:
          let pp = withDefAttr "" attrval "subpath" (p: "/" + p);
          in pth + pp;
        stringOvr = n: v:
          let val = if isURLValue n v then githubSrcURL v else v; in { name = n; value = val; };
        pathOvr = n: v: { name = n; value = v; };
        hackageOvr = n: v: { name = n; value = v.version; };
        githubOvr = n: v:
          let ghsrc = githubSrcFetch ({ ref = "master"; } // v);
              isrc = hasDefAttr ghsrc srcs n;
              asPath = x: { string = x; path = /. + x; }."${builtins.typeOf x}";
              r = { name = n; value = asPath (plusSubpath isrc v); };
          in if !hydraRun && builtins.hasAttr "local" v
             then stringOvr n (plusSubpath v.local v)
             else r;
        srcAttrList = mapAttrs mkSrcOvr prjSrcs;
    in builtins.listToAttrs srcAttrList;

  ######################################################################
  # Haskell packages

  hpkgs =
    let hextends = withDefAttr hSources overrides "haskell-packages"
                   (hpkg: pkgs.lib.composeExtensions hSources (hpkg parameters));
    in pkgs.haskell.packages."${ghcver}".extend(hextends);

  isHaskellPackage = n: let e = hpkgs."${n}" or null; in if e == null then false else true;

  haskellProjectSources =
    # Only the haskell sources specified by calling the addSrcs input
    # with the current parameters as an argument and returning
    # everything it specifies under the "haskell-packages" attribute.
    let f = s: s.haskell-packages or {}; in projectSources f;

  hSources = pkgs.haskell.lib.packageSourceOverrides hSrcOverrides;

  hSrcOverrides =
    # Return an attrset of haskell packages and the corresponding
    # source input for that package.  The source input is determined
    # based on the rules of projectSourceOverrides above, but any
    # source that is a path should exist.
    #
    # If the source input is a non-existent path, then this either indicates:
    #
    #    * an underspecified srcs/addSrcs input (needs to be fixed in the caller), OR
    #
    #    * a subpath source that does not yet exist in this repo commit hash
    #
    # As an example of the latter case, if top level repo R1 has repo
    # R2 as a submodule, and R2 contains two haskell modules (R2a and
    # R2b), each in a subpath of the R2 repo, then if R2 adds a new
    # haskell module (R2c), then inputs need to be defined for that
    # module, but the checkout of older R2 (as dictated by
    # yet-to-be-updated submodules of R1) will *not* have R2c present.
    #
    # To handle this latter case, any input that is a non-existent
    # path and the input includes a subpath specification, then an
    # empty cabal file is created that will satisfy cabal2nix
    # evaluation of inputs, but which will not provide the actual
    # module (if it were built, but it shouldn't be because there
    # should be no references to that module in the older commit).  If
    # there is no subpath, then the input should have been provided
    # and an abort is performed instead.
    let hsrcs = projectSourceOverrides haskellProjectSources;
        sl = mapAttrs toSrc hsrcs;
        toSrc = n: v:
          let snv = { name = n; value = v; };
              snv_exists = checkAttrValuePathExists snv;
              missing_input = { name = n;
                                value = pkgs.stdenv.mkDerivation {
                                  name = "${n}-missing";
                                  buildCommand = ''
                                    mkdir $out
                                    echo name: ${n} >> $out/${n}.cabal
                                    echo version: 0.0.0.1 >> $out/${n}.cabal
                                    '';
                                };
                              };
              fake_or_abort =
                if builtins.hasAttr "subpath" (haskellProjectSources."${n}")
                then missing_input
                else abort ("Path for haskell input ${n} does not exist: " +
                            builtins.toString v);
          in hasDef fake_or_abort snv_exists;
    in builtins.listToAttrs sl;

  htargets =
    builtins.listToAttrs
      (map (n: {name = n; value = hpkgs."${n}"; })
        (builtins.filter isHaskellPackage
          (projectSourceTargetNames allProjectSources)));

  shell_htargets =
    let pkgWithTools = n: pkgs.haskell.lib.addExtraLibraries hpkgs."${n}"
                          [ pkgs.haskell.packages.${ghcver}.cabal-install ];
        pkgAttr = n: { name = n; value = pkgWithTools n; };
    in
      builtins.listToAttrs
        (map pkgAttr
          (builtins.filter isHaskellPackage
            (projectSourceTargetNames allProjectSources)));

  haskellTargets =
    let inShell = false;
        # inShell = pkgs.lib.inNixShell; <-- modifies packages, no binary substitution
    in if inShell then shell_htargets else htargets;

  ######################################################################
  # General targets

  genTargetSrcs =
    let f = s: builtins.removeAttrs s [ "haskell-packages" ];
    in projectSources f;

  genTargets =
    let srcNames = builtins.attrNames genTargetSrcs;
        drvWithSrcOverride = n:
          { name = n;
            value = (globaltgts.${n} or pkgs.${n}).overrideDerivation
              (d: { src = genTargetSrcs.${n}; });
          };
    in builtins.listToAttrs (map drvWithSrcOverride srcNames);

  ######################################################################

  globaltgts = withDefAttr {} overrides "global" (o: o parameters);

in haskellTargets // genTargets // globaltgts;

}
