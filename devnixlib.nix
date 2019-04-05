rec {

  mapAll = fl: vl: builtins.concatLists (map (v: map (f: f v) fl) vl);

  mapEachCombination = f: attrs: map f (allCombinations attrs);

  allCombinations = attrs:
    let withNames = nl:
          let name = builtins.head nl;
              this = map (v: { "${name}" = v; }) attrs."${name}";
              rest = withNames (builtins.tail nl);
              joinRest = a: map (r: r // a) rest;
           in if nl == [] then [] else if rest == [] then this
              else builtins.concatLists (map joinRest this);
    in withNames (builtins.attrNames attrs);

  # Arguments are a function and an attribute set.  Calls the function
  # with name: value: arguments for each attribute in the set.
  # Returns a list of the results of calling the function.
  mapAttrs = f: set: with builtins;
    let names = attrNames set;
    in map (n: f n set."${n}") names;

  mapAttrsOrdering = f: ordf: set: with builtins;
    let names = builtins.sort ordf (attrNames set);
    in map (n: f n set."${n}") names;


  # Remove attributes from the set for which `pred attrname attrvalue`
  # returns false.
  filterAttrs = pred: set:
    let nameValuePair = name: value: { inherit name value; };
        chkEntry = name: let v = set.${name};
                         in if pred name v
                            then [(nameValuePair name v)]
                            else [];
    in with builtins; listToAttrs (concatMap chkEntry (attrNames set));


  hasDef = d: v: if v == null then d else v;

  hasDefAttr = d: s: a:
    if builtins.hasAttr a s
    then hasDef d (builtins.getAttr a s)
    else d;

  withDef = d: v: f: if v == null then d else f v;

  withDefAttr = d: s: a: f:
    if builtins.hasAttr a s
    then withDef d (builtins.getAttr a s) f
    else d;

  overridePropagatingAttrs = propAttrs: orig: upd:
    let ca = builtins.intersectAttrs orig upd;
        can = builtins.attrNames ca;
        cau = builtins.foldl' propEach ca can;
        propEach = attrs: aname:
          attrs // { "${aname}" = builtins.foldl' (propOne aname) attrs."${aname}" propAttrs; };
        propOne = aname: aset: aprop:
          aset // { "${aprop}" = orig."${aname}"."${aprop}"; };
    in orig // upd // cau;

  # ----------------------------------------------------------------------

  # The githubsrc constructor creates an attrset that describes a
  # remote github (or gitlab) source location for code.  The primary
  # identification is "team" and "repo", which allows a reference to
  # the github/gitlab repository to be constructed.
  #
  # Attributes:
  #
  #    * type :: "github"
  #
  #    * team :: "team name on github"
  #
  #    * repo :: "repository name on github"
  #
  #    * ref :: "reference to checkout"
  #        -- a branch, tag, or commit hash.
  #        -- Default = master
  #
  #    * subpath = "path in repository where build should occur"
  #        -- optional
  #
  #    * urlBase = "alternate URL base string"
  #        -- this is the prefix of the URL reference that will be generated
  #        -- Default = "https://github.com/"
  #        -- this can also be used to access private repositories:
  #            1. create a no-password SSH key
  #            2. install the public key as a deployment key in the repository
  #            3. Update the .ssh/config to contain:
  #                 Host foo-github
  #                    HostName github.com
  #                    User     git
  #                    IdentityFile ~/.ssh/private-key
  #            4. Set the urlBase here to "foo-github"
  githubsrc = team: repo: { type = "github"; inherit team repo; ref = "master";
                            __functor = self: r: self // { ref = r; };
  };

  hackageVersion = version: { type = "hackageVersion"; inherit version; };

  isSrcType = t: n: v: (v.type or "") == t;

  gitSources = srcs:
    let isGithub = isSrcType "github";
        # isGithub = n: v: srcs."${n}".type == "github";
    in filterAttrs isGithub srcs;

  # gitURLSplit -- Given a URL git reference, split it into an attrset
  # of base, team, repo, and subpath
  #
  gitURLSplit = url:
    let sshSplt = builtins.split ":" url;
        httpSplt = builtins.split "/" url;
        base = if startsWith "git@" url
               then builtins.elemAt sshSplt 0
               else builtins.concatStringsSep "/" (elemsAt httpSplt [0 2 4]);
        uri = if startsWith "git@" url
              then builtins.elemAt sshSplt 2
              else builtins.substring (builtins.stringLength base + 1) (builtins.stringLength url) url;
        uriSplt = builtins.split "/" uri;
        team = builtins.elemAt uriSplt 0;
        repo = builtins.elemAt uriSplt 2;
        pathElems = builtins.genList (n: 4 + (2 * n)) ((builtins.length uriSplt - 3) / 2);
        path = builtins.concatStringsSep "/" (elemsAt uriSplt pathElems);
    in { team = team; repo = repo; base = base; subpath = path; };

  githubSrcFetch = { team ? "GaloisInc", repo, ref ? "master" }:
    githubSrcURL "https://api.github.com/repos/${team}/${repo}/tarball/${ref}";

  githubSrcURL = url: builtins.fetchTarball { inherit url; };

  # ----------------------------------------------------------------------

  dbg = n: v: builtins.trace (n + " ::") (builtins.trace v v);

  strictHaskellFlags = lib: drv:
    builtins.foldl' lib.appendConfigureFlag drv [
      "--ghc-option=-Werror"
      "--ghc-option=-Wcompat"
    ];

  # Duplication of the version in pkgs.haskell.lib (duplicated so that pkgs isn't required here).
  overrideCabal = drv: f: (drv.override (args: args // {
    mkDerivation = drv: (args.mkDerivation drv).override f;
  })) // {
    overrideScope = scope: overrideCabal (drv.overrideScope scope) f;
  };

  # Based on similar functions (but not present in) pkgs.haskell.lib.
  addTestTools = drv: xs:
    overrideCabal drv (drv: { testToolDepends = (drv.testToolDepends or []) ++ xs; });

  # elemsAt -- Given two lists, return only the elements of the first
  # referred to by the indices in the second.

  elemsAt = l: with builtins;
    let appI = a: i: let e = elemAt l i; in a ++ [e]; in foldl' appI [];

  # gitTreeSources: For each element in the gitTree, call onEach with
  # { name; url; rev; } corresponding to the "repo name", the full
  # URL, and the revision from the gitTree.  Returns the list of
  # onEach results.
  #
  # The name argument will be constructed by using the final element
  # of the submodule name or the url (after the last "/", and
  # appending "-src".
  #
  # The full URL will convert "git@github.com:" into
  # "https://github.com/" for generic entries to allow access without
  # a key, but it will not touch other "git@...." references; those
  # will be assumed to have a hostname that the hydra user's
  # .ssh/config maps to a specific git host and local private key for
  # access.
  #
  # Additionally, any ".git" suffix will be removed from the URL.

  gitTreeSources = numLevels: onEach: gitTree:
    let mkSrcInp = lvls: e:
            let this = onEach { name = entryName e;
                                url = entryURL e;
                                rev = entryRev e;
                              };
                rest = if lvls < 1 then []
                       else builtins.concatLists
                       (builtins.map (mkSrcInp (lvls - 1)) (e.submods or []));
            in [ this ] ++ rest;
        entryName = e:
          let nm = if (builtins.hasAttr "submodule" e)
                   then splitLast "/" e.submodule
                   else splitLast "/" e.uri;
          in (removeSuffix ".git" nm) + "-src";
        entryURL = e:
          replacePrefix "git@github.com:" "https://github.com/"
            (removeSuffix ".git" e.uri);
        entryRev = e: e.revision;
        gTree = builtins.fromJSON (builtins.readFile gitTree);
    in if gitTree == null || numLevels == 0
       then []
       else builtins.concatLists (builtins.map (mkSrcInp (numLevels - 1)) [gTree]);

  last = l:
    let ll = builtins.length l;
    in if ll == 0 then "<none>" else builtins.elemAt l (ll - 1);

  splitLast = m: s: last (builtins.split m s);

  removeSuffix = (import <nixpkgs/lib>).removeSuffix;

  replacePrefix = rmv: rpl: str:
    let rl = builtins.stringLength rmv;
        sl = builtins.stringLength str;
    in if builtins.substring 0 rl str == rmv
       then rpl + builtins.substring rl sl str
       else str;

  startsWith = m: s:
    let ml = builtins.stringLength m;
    in builtins.substring 0 ml s == m;

  endsWith = m: s:
    let ml = builtins.stringLength m;
        sl = builtins.stringLength s;
    in if ml > sl then false
       else builtins.substring (sl - ml) sl s == m;

  # ----------------------------------------------------------------------

  recentHaskellHashes = builtins.fetchurl {
    url = "https://api.github.com/repos/commercialhaskell/all-cabal-hashes/tarball/hackage";
  };

  defaultPkgs = nixpkgs: sys: ovr: freshHaskell:
    let s = if sys == null then builtins.currentSystem else sys;
        o = { packageOverrides = if ovr == null then p: {} else ovr; };
        freshH = p: if builtins.isBool freshHaskell
                    then { all-cabal-hashes = recentHaskellHashes; }
                    else { all-cabal-hashes = freshHaskell; };
        oChain = f: g: a: f a // g a;
        h = if !builtins.isBool freshHaskell || freshHaskell
            then o: p: o // { packageOverrides = oChain freshH o.packageOverrides; }
            else o: o;
        c = h o;
    in import nixpkgs { system = s; config = c; };
}
