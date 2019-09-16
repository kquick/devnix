rec {


  id =
    # Unit function: simply returns its input
    x: x;


  dot =
    # Dot is (f . g): functional composition.
    f: g: a: f (g a);

  mapAll =
    # Given a list of functions and a list of values, return the list
    # made up of calling every function with every value.
    fl:  # list of functions to call
    vl:  # list of values to pass to the functions
    builtins.concatLists (map (v: map (f: f v) fl) vl);

  mapEachCombination =
    # Apply a function to each possible attribute/value combination.
    # Calls allCombinations to get the possible attribute/value
    # combinations.
    #
    # Returns the list of results of calling the function
    #
    f:     # function to apply to each possible attrset
    attrs: # input attrset where every value is a list of possible values
    map f (allCombinations attrs);

  allCombinations =
    # Given an attrset where each attribute's value is a list, return
    # a list of attrsets that represent every possible attribute/value
    # combination.
    #
    # Example:
    #   { foo = [ "bar" "baz" ];
    #     cow = [ "moo" "milk" ];
    #   }
    #
    # The result would be:
    #   [ { foo = "bar"; cow = "moo"; }
    #   , { foo = "bar"; cow = "milk"; }
    #   , { foo = "baz"; cow = "moo"; }
    #   , { foo = "baz"; cow = "milk"; }
    #   ]
    #
    attrs:
    let withNames = nl:
          let name = builtins.head nl;
              this = map (v: { "${name}" = v; }) attrs."${name}";
              rest = withNames (builtins.tail nl);
              joinRest = a: map (r: r // a) rest;
           in if nl == [] then [] else if rest == [] then this
              else builtins.concatLists (map joinRest this);
    in withNames (builtins.attrNames attrs);

  mapAttrs =
    # For every attribute in the input attrset, call a function with
    # the attr name and value as arguments.  Return the list of
    # function results.
    f:   # function called with: attrname attrvalue
    set: # input attrset to process
    with builtins;
    let names = attrNames set;
    in map (n: f n set."${n}") names;

  mapAttrsOrdering =
    # For every attribute in the input attrset, as ordered by the
    # ordering function, call a function with that attr name and value
    # as arguments.  Return the list of function results.
    #
    # Like mapAttrs but with an additional function to control the
    # order of the attributes processed.
    #
    f:    # function called with: attrname attrvalue
    #
    ordf: # ordering function, called with: attrname1 attrname2,
          # returns bool of attrname1 < attrname2
    #
    set:  # input attrset to process
    #
    with builtins;
    let names = builtins.sort ordf (attrNames set);
    in map (n: f n set."${n}") names;


  filterAttrs =
    # Remove attributes from the set for which the supplied predicate
    # function returns false.
    pred:  # predicate function called with: attrname attrvalue
    set:   # input attrset to process
    let nameValuePair = name: value: { inherit name value; };
        chkEntry = name: let v = set.${name};
                         in if pred name v
                            then [(nameValuePair name v)]
                            else [];
    in with builtins; listToAttrs (builtins.concatLists
                                   (builtins.map chkEntry (attrNames set)));


  hasDef =
    # Returns a default value if the input value is null.
    d:  # default value
    v:  # input value
    if v == null then d else v;

  hasDefAttr =
    # Returns a default value if the named attribute does not exist in
    # the input attrset or if it exists but its value is null.
    d:  # default value
    s:  # input attrset
    a:  # attribute name to retrieve
    if builtins.hasAttr a s
    then hasDef d (builtins.getAttr a s)
    else d;

  withDef =
    # Calls a function on the non-null input value or returns a
    # default value if the input value was null.
    d:  # default value
    v:  # input value
    f:  # function to call on the value
    if v == null then d else f v;

  withDefAttr =
    # Calls a function to operate on the specified attribute in the
    # input set, or returns a default value if that attribute does not
    # exist in the set or if its value is null.
    d:  # default value
    s:  # input attribute set
    a:  # attribute name to retrieve (as a string)
    f:  # function to call on the attribute's value
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


  requireAttrValuePath =
    # Given an attribute name and its value, ensure that the value is
    # a valid, existing path or abort if it is not.
    { name, value } @ a:
    # KWQ: if a string, try converting the string to a path and validating the path
    let isP = builtins.typeOf value == "path";
        r = builtins.tryEval (builtins.pathExists value);
        exists = r.success && r.value;
        ckP = if exists then a
              else abort "Path for ${name} does not exist: ${value}";
    in builtins.deepSeq isP (if isP then (builtins.deepSeq ckP ckP) else a);


  # ----------------------------------------------------------------------

  githubsrc =
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
    team:  # team name on github
    repo:  # repo name on github
    { type = "github";
      inherit team repo;
      ref = "master";
      __functor = self: r: self // { ref = r; };
    };

  hackageVersion =
    # The hackageVersion constructor creates an attrset that describes
    # a specific version of a Haskell package obtained from the
    # hackage site.  This version may or may not be the same as the
    # default version referenced by the current nixpkgs set.
    version:  # the specific version of the Haskell package (as a string)
    { type = "hackageVersion";
      inherit version;
    };

  # ----------------------------------------------------------------------

  isSrcType =
    # A predicate to test that a source specification is of the
    # desired type.
    #
    # Takes a name and value to make it easy to use with mapAttrs.
    t:   # the desired type
    n:   # source name (ignored)
    v:   # source value
    (v.type or "") == t;

  gitSources =
    # Returns only the git sources from the input set of source
    # specifications.
    srcs:
    let isGithub = isSrcType "github";
        # isGithub = n: v: srcs."${n}".type == "github";
    in filterAttrs isGithub srcs;

  pathSources = srcs:
    # Returns only the local path sources from the input set of source
    # specifications.
    let isPath = n: v: builtins.elem (builtins.typeOf v) [ "string" "path" ];
    in filterAttrs isPath srcs;


  isURLValue =
    # Predicate returning true if the value argument is a URL.
    #
    # Takes a name and value to make it easy to use with mapAttrs.
    n:  # ignored; presumably the attribute name
    v:  # value to test for being a URL
    builtins.typeOf v == "string" && startsWith "https://" v;


  gitURLSplit =
    # Given a URL git reference, split it into an attrset of base,
    # team, repo, and subpath.  Note that this is very similar to a
    # "githubsrc" attrset, but it is not quite the same.
    #
    # This function has lots of assumptions about the format of a URL
    # reference to a github or gitlab repository.
    url:
    let sshSplt = builtins.split ":" url;
        httpSplt = builtins.split "/" url;
        base = if startsWith "git@" url
               then builtins.elemAt sshSplt 0
               else builtins.concatStringsSep "/" (elemsAt httpSplt [0 2 4]);
        uri = if startsWith "git@" url
              then builtins.elemAt sshSplt 2
              else builtins.substring
                     (builtins.stringLength base + 1)
                     (builtins.stringLength url)
                     url;
        uriSplt = builtins.split "/" uri;
        team = builtins.elemAt uriSplt 0;
        repo = builtins.elemAt uriSplt 2;
        pathElems = builtins.genList (n: 4 + (2 * n))
                                     ((builtins.length uriSplt - 3) / 2);
        path = builtins.concatStringsSep "/" (elemsAt uriSplt pathElems);
    in { team = team; repo = repo; base = base; subpath = path; };


  githubSrcFetch =
    # Given a githubsrc specification, fetch the source and return the
    # local path to the fetched source.
    #
    # Internally converts the input githubsrc specification to the
    # actual URL that should be used to retrieve that source from
    # github/gitlab.
    ghs:  # ghs is the return from githubsrc
    let base = ghs.urlBase or "https://github.com/";
        refURL = "${base}${ghs.team}/${ghs.repo}";
        url = if base == "https://github.com/"
              then "https://api.github.com/repos/${ghs.team}/${ghs.repo}/tarball/${ghs.ref}"
              else
              let anyGitlab = builtins.match "https://(.*gitlab[^/]*/).*" base; in
              if anyGitlab != null && builtins.length anyGitlab == 1
              then "https://${builtins.elemAt anyGitlab 0}${ghs.team}/${ghs.repo}/-/archive/${ghs.ref}/${ghs.repo}-${ghs.ref}.tar.bz2"
              else throw ("devnixlib: Do not know how to fetch tarball from: ${refURL}" +
                          "; probably a private url, try a \"local\" override");
        getTheURL = githubSrcURL url;
    in getTheURL;

  githubSrcURL =
    # Given a github/gitlab URL, fetch the source from that git
    # location and return the local store path where the fetched
    # source lives (for the tarball-ttl period, defaulting to 1 hour;
    # see "$ nix show-config").
    url: builtins.fetchTarball { inherit url; };

  # ----------------------------------------------------------------------

  dbg =
    # Convenience debugging function that traces both a name and a value
    n:  # name to trace
    v:  # value to trace
    builtins.trace (n + " ::") (builtins.trace v v);

  strictHaskellFlags =
    # Applies various flags to a Haskell package derivation to cause
    # it to be built strictly (e.g. turn warnings into errors).
    lib:  # The haskell library providing "appendConfigureFlag"
    drv:  # the haskell package derivation to be made strict
    builtins.foldl' lib.appendConfigureFlag drv [
      "--ghc-option=-Werror"
      "--ghc-option=-Wcompat"
    ];


  overrideCabal =
    # Duplication of the version of overrideCabal in pkgs.haskell.lib
    # (duplicated so that pkgs isn't required here).
    drv: f: (drv.override (args: args // {
      mkDerivation = drv: (args.mkDerivation drv).override f;
    })) // {
      overrideScope = scope: overrideCabal (drv.overrideScope scope) f;
    };


  addTestTools =
    # Adds specific dependencies to the testing (i.e. check) phase of
    # a derivation.  Based on similar functions (but not present in)
    # pkgs.haskell.lib.
    drv:  # derivation to update
    xs:   # list of test dependency packages to add
    overrideCabal drv
                  (d: { testToolDepends = (d.testToolDepends or []) ++ xs; });

  notBroken =
    # Haskell packages are aggressively marked as broken, but there
    # are some local overrides that can be applied so that they can be
    # built successfully.  This function re-enables the build of the
    # passed haskell package derivation by disabling the broken flag.
    drv:  # haskell package derivation to "un-break"
    overrideCabal drv (d: { broken = false; });

  elemsAt =
    # Given two lists, return only the elements of the first referred
    # to by the indices in the second.
    l:  # input list of elements
    with builtins;
    let appI = a: i: let e = elemAt l i; in a ++ [e]; in foldl' appI [];


  gitTreeSources =
    # For each element in the gitTree, call onEach with { name; url;
    # rev; } corresponding to the "repo name", the full URL, and the
    # revision from the gitTree.  Returns the list of onEach results.
    #
    # The name argument will be constructed by using the final element
    # of the submodule name or the url (after the last "/", and
    # appending "-src".
    #
    # The full URL will convert "git@github.com:" into
    # "https://github.com/" for generic entries to allow access
    # without a key, but it will not touch other "git@...."
    # references; those will be assumed to have a hostname that the
    # hydra user's .ssh/config maps to a specific git host and local
    # private key for access.
    #
    # Additionally, any ".git" suffix will be removed from the URL.
    #
    numLevels:  # number of levels to descend in the input tree
    onEach:     # function to call with { name, url, rev }
    gitTree:    # input gittree output
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

  last =
    # Return the last element in the input list, or the string
    # "<none>" if the input list is empty.
    l:  # input list
    let ll = builtins.length l;
    in if ll == 0 then "<none>" else builtins.elemAt l (ll - 1);

  splitBy =
    # Splits the input string by the specified regex and returns the
    # portions split by the regex.  The result is always a list of at
    # least one element (the prefix of the string up until the first
    # regex point or the end of the string).
    m:  # regex of split marker points
    s:  # input string to split
    builtins.filter builtins.isString (builtins.split m s);

  assocEqListHasKey =
    # An assocEqList is a list of strings where each string is of
    # the form "key=value".  This function checks each entry to see
    # if the key matches the input key specified and returns true if
    # it is present.
    key:  # name of key to search for
    aeql:
    builtins.any (e: key == builtins.head (splitBy "=" e)) aeql;

  assocEqListLookup =
    # An assocEqList is a list of strings where each string is of the
    # form "key=value".  This function returns the value for the
    # specified key, or null if the key does not exist in the list.
    # Returns the first entry if the key appears multiple times in the
    # list.
    key:  # name of key to search for
    aeql:
    let m = builtins.filter (e: key == builtins.head (splitBy "=" e)) aeql;
        keylen = builtins.stringLength key;
        rmvkey = v: builtins.substring (keylen + 1) (builtins.stringLength v) v;
    in if 0 == builtins.length m
       then null
       else rmvkey (builtins.head m);

  splitLast =
    # Splits the input string into regex matches and returns the last
    # regex match.
    m:  # regex to match
    s:  # input string
    last (builtins.split m s);

  removeSuffix = (import <nixpkgs/lib>).removeSuffix;

  replacePrefix =
    # If the string starts with a specific prefix, replace that prefix
    # with an alternate prefix.  If the string doesn't start with the
    # specific prefix, simply return it unchanged.
    rmv:  # prefix to search for
    rpl:  # replacement prefix
    str:  # input string
    let rl = builtins.stringLength rmv;
        sl = builtins.stringLength str;
    in if builtins.substring 0 rl str == rmv
       then rpl + builtins.substring rl sl str
       else str;

  startsWith =
    # Predicate returning true if the input string starts with the
    # specified prefix.
    m:  # prefix to check for
    s:  # input string
    let ml = builtins.stringLength m;
    in builtins.substring 0 ml s == m;

  endsWith =
    # Predicate returning true if the input string ends with the
    # specified suffix.
    m:  # suffix to check for
    s:  # input string
    let ml = builtins.stringLength m;
        sl = builtins.stringLength s;
    in if ml > sl then false
       else builtins.substring (sl - ml) sl s == m;

  # ----------------------------------------------------------------------

  recentHaskellHashes =
    # Returns the local nix store path of the result of fetching the
    # latest haskell hashes.  The returned hashes are cached for the
    # tarball-ttl period, defaulting to 1 hour; see:
    #
    #    $ nix show-config
    #
    builtins.fetchurl {
      url = "https://api.github.com/repos/commercialhaskell/all-cabal-hashes/tarball/hackage";
    };

  defaultPkgs =
    # Returns the set of nixpkgs to use, applying any system and
    # config settings to the packages specification.
    nixpkgs:      # input path to the nix packages
    sys:          # system for specification (null for current system)
    ovr:          # any package overrides (null for none)
    #
    freshHaskell: # if true, get the most recent haskell package hashes
                  # if a path, use that path as the most recent
                  # haskell package hashes if false/null, just use the
                  # nixpkgs haskell hashes.
    #
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

  defaultPkgArgs =
    # Returns the arguments to specify to the nixpkgs import
    # operation, applying any system and config settings to the
    # packages specification.
    sys:          # system for specification (null for current system)
    ovr:          # any package overrides (null for none)
    #
    freshHaskell: # if true, get the most recent haskell package hashes
                  # if a path, use that path as the most recent
                  # haskell package hashes if false/null, just use the
                  # nixpkgs haskell hashes.
    #
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
    in { system = s; config = c; };
}
