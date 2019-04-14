with import ./devnixlib.nix;

let

  gitProject = url:
    {
      type = "git";
      url = url;
      entrypoint = ./configs.nix;
      # extraReleaseInputs
    };

  gitProjectFromDecl = decl-file:
    let json = builtins.fromJSON (builtins.readFile decl-file);
        stdinps = [ "project" "hydra-jobsets" ];
        ei = builtins.removeAttrs json.inputs stdinps;
    in gitProject json.inputs.project.value //
       {
         entrypoint = json.nixexprpath;
         extraReleaseInputs = ei;
       };

  jobsetSpec = project: gitTree: gitTreeAdj: addSrcs: inpAdj: variant: params:
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
                enableemail = false;
                inputs = inputSpec gitTree gitTreeAdj addSrcs inpAdj variant params //
                  {
                    project = {  # the input containing the job expression (release.nix)
                      type = project.type;
                      value =
                        let extra = withDefAttr "" project "branch" (e: " " + e);
                            # assumes url is the main value for now
                        in project.url + extra;
                      emailresponsible = false;
                    };
                    hydraRun = {  # This indicates that this is a hydra build, not a user build
                      type = "boolean";
                      value = "true";
                      emailresponsible = false;
                    };
                  }
                  // hasDefAttr {} project "extraReleaseInputs";
              };
    };

  inputSpec = gitTree: gitTreeAdj: addSrcs: inpAdj: variant: params:
    let genVal = type: value: { inherit type value; emailresponsible = false; };

        cfg = params // { inherit variant; };

        strVals = set:
            let genEnt = name: value: { inherit name;
                                        value = genVal "string" value;
                                      };
            in builtins.listToAttrs (mapAttrs genEnt set);


        genGTreeInp =
            let mkInp = { name, url, rev }:
                          # This gitTree instance should either
                          # override *every* addSrc with the same URL
                          # (there may be multiple due to subpaths)
                          # ignoring the input name, or it should be
                          # its own instance with the generated name.
                          let aSrcMatches = filterAttrs sameURL inpSrcs;
                              sameURL = _: s: urlVal s == url;
                              aSrcMNames = builtins.attrNames aSrcMatches;
                              valAttr = { value = genVal "git" "${url} ${rev}"; };
                              names = if builtins.length aSrcMNames == 0 then [ name ]
                                      else map (n: n + "-src") aSrcMNames;
                          in builtins.map (n: valAttr // { name = n; }) names;
                adj = if gitTreeAdj == null then id else gitTreeAdj;
            in dot mkInp adj;
        gtSrcs = builtins.concatLists (gitTreeSources 2 genGTreeInp gitTree);

        # use all sources, irrespective of packaging, but only where this is
        # a remotely-fetchable source that should be captured in a job source.
        inpSrcs = let r = builtins.removeAttrs srclst [ "haskell-packages" ];
                      h = srclst.haskell-packages or {};
                  in gitSources (r // h);

        urlVal = v: "${urlBase v}${v.team}/${v.repo}";
        urlBase = v: v.urlBase or "https://github.com/";

        genSrcInp = name: value:
                      {
                        name = "${name}-src";
                        value = genVal "git" (urlVal value + " " + (value.ref or "master"));
                      };
        aSrcs = mapAttrs genSrcInp inpSrcs;

        srclst = addSrcs cfg;  # variant is branch

        sourceVals =
            let otherInps  =
                  let mkFrshI = v:
                        [ { name = "freshHaskellHashes";
                            value = genVal "path" "${freshURL} ${freshPeriod}";
                          } ];
                      freshURL = https://api.github.com/repos/commercialhaskell/all-cabal-hashes/tarball/hackage;
                      freshPeriod = builtins.toString (24 * 60 * 60); # seconds
                  in withDefAttr []
                     (hasDefAttr {} srclst "haskell-packages") "freshHaskellHashes"
                     mkFrshI;
                prepS = s: builtins.listToAttrs (map (inpAdj cfg) s);
                s1 = prepS aSrcs;
                s2 = prepS gtSrcs;
                s3 = prepS otherInps;
            in s1 // s2 // s3;

    in (strVals cfg) // sourceVals //
       {
       #   hackage-index = {
       #          type = "path";
       #          value = "https://hackage.haskell.org/01-index.tar.gz 86400";
       #          emailresponsible = false;
       #   };
       };

  jobset_list = project: variant: parameters: gitTree: gitTreeAdj: addSrcs: inpAdj:
    let jss = jobsetSpec project gitTree gitTreeAdj addSrcs inpAdj variant;
    in mapEachCombination jss parameters;

  mkJobset = { pkgs ? import <nixpkgs> {}
             , variant ? "master"
             , gitTree ? null
             , gitTreeAdj ? null
             , addSrcs ? {}: {}
             , inpAdj ? cfg: x: x
             , project
             , parameters ? {}
             }:
    jobset_list project variant parameters gitTree gitTreeAdj addSrcs inpAdj;

  mkJobsetsDrv = pkgs: jslists:
    pkgs.stdenv.mkDerivation {
      name = "jobsets";
      phases = [ "installPhase" ];
      installPhase = "cp $jsonfile $out";
      jsonfile = builtins.toFile "jobsets.json"
                 (builtins.toJSON
                   (builtins.listToAttrs (builtins.concatLists jslists)));
    };

  # Given the output of mkJobset, enables email notifications for that jobset list.
  enableEmail = map ({name, value}: { inherit name;
                                      value = value // { enableemail = true; };
                                    });

in { inherit gitProjectFromDecl mkJobset mkJobsetsDrv enableEmail; }
