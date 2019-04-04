with import ./devnixlib.nix;

let

  gitProject = url:
    {
      type = "git";
      url = url;
      entrypoint = ./configs.nix;
    };

  jobsetSpec = project: gitTree: gitTreeAdj: addSrcs: variant: params:
    let name = builtins.concatStringsSep "-" (mapAttrsOrdering (n: v: v) ordrf params);
        ordrf = a: b: if a == "system" then true else a < b;
        desc = builtins.concatStringsSep ", " (mapAttrs (n: v: "${n} ${v}") params);
    in
    { name = "${name}-${variant}";
      value = { checkinterval = 300;
                schedulingshares = 1;
                emailoverride = "kquick@galois.com";
                keepnr = 3;
                description = "Build ${variant} with ${desc}";
                nixexprinput = "project";
                nixexprpath = project.entrypoint;
                enabled = 1;
                hidden = false;
                enableemail = true;
                inputs = inputSpec gitTree gitTreeAdj addSrcs variant params //
                  {
                    project = {  # the input containing the job expression (release.nix)
                      type = project.type;
                      value =
                        let extra = withDefAttr "" project "branch" (e: " " + e);
                            # assumes url is the main value for now
                        in project.url + extra;
                      emailresponsible = false;
                    };
                    nixpkgs = {
                      type = "git";
                      value = "https://github.com/NixOS/nixpkgs-channels nixos-unstable";  # KWQ
                      emailresponsible = false;
                    };
                  }
                  // hasDefAttr {} project "extraReleaseInputs";
              };
    };

  inputSpec = gitTree: gitTreeAdj: addSrcs: variant: params:
    let genVal = type: value: { inherit type value; emailresponsible = false; };

        cfg = params // { inherit variant; };

        strVals = set:
            let genEnt = name: value: { inherit name;
                                        value = genVal "string" value;
                                      };
            in builtins.listToAttrs (mapAttrs genEnt set);


        genGTreeInp =
            let mkInp = { name, url, rev }:
                          { name = name;
                            value = genVal "git" "${url} ${rev}";
                          };
            in if gitTreeAdj == null then mkInp else a: mkInp (gitTreeAdj a);
        gtSrcs = gitTreeSources 2 genGTreeInp gitTree;

        # use all sources, irrespective of packaging, but only where this is
        # a remotely-fetchable source that should be captured in a job source.
        aSrcs = let r = builtins.removeAttrs srclst [ "haskell-packages" ];
                    h = srclst.haskell-packages or {};
                in mapAttrs genSrcInp (gitSources (r // h));
        genSrcInp = name: value:
                      let urlVal = v: "${urlBase}${v.team}/${v.repo}.git ${v.ref or "master"}";
                          urlBase = "https://github.com/";
                      in { name = "${name}-src";
                           value = genVal "git" (urlVal value);
                         };

        srclst = addSrcs cfg;  # variant is branch

        sourceVals =
            let otherInps  =
                  let mkFrshI = v:
                        [ { name = "freshHaskellHashes";
                            value = genVal "path" "${freshURL} ${freshPeriod}";
                          } ];
                      freshURL = https://api.github.com/repos/commercialhaskell/all-cabal-hashes/tarball/hackage;
                      freshPeriod = builtins.toString (24 * 60 * 60); # seconds
                  in withDefAttr [] srclst "freshHaskellHashes" mkFrshI;
            in builtins.listToAttrs (aSrcs ++ gtSrcs ++ otherInps);

    in (strVals cfg) // sourceVals //
       {
       #   hackage-index = {
       #          type = "path";
       #          value = "https://hackage.haskell.org/01-index.tar.gz 86400";
       #          emailresponsible = false;
       #   };
       };

  jobset_list = project: variant: parameters: gitTree: gitTreeAdj: addSrcs:
    let jss = jobsetSpec project gitTree gitTreeAdj addSrcs variant;
    in mapEachCombination jss parameters;

  mkJobset = { pkgs ? import <nixpkgs> {}
             , variant ? "master"
             , gitTree ? null
             , gitTreeAdj ? null
             , addSrcs ? {}: {}
             , project
             , parameters ? {}
             }:
    jobset_list project variant parameters gitTree gitTreeAdj addSrcs;

  mkJobsetsDrv = pkgs: jslists:
    pkgs.stdenv.mkDerivation {
      name = "jobsets";
      phases = [ "installPhase" ];
      installPhase = "cp $jsonfile $out";
      jsonfile = builtins.toFile "jobsets.json"
                 (builtins.toJSON
                   (builtins.listToAttrs (builtins.concatLists jslists)));
    };

in { inherit gitProject mkJobset mkJobsetsDrv; }
